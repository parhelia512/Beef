using System.Collections;
using System.Reflection;
using System.Diagnostics;

namespace System
{
	struct DbgRawAllocData
	{
		public Type mType;
		public void* mMarkFunc;
		public int32 mMaxStackTrace;

		public struct Unmarked<T>
		{
			static DbgRawAllocData sRawAllocData;
			public static DbgRawAllocData* Data
			{
				get
				{
					if (sRawAllocData.mMaxStackTrace == 0)
					{
						sRawAllocData.mMarkFunc = null;
						sRawAllocData.mMaxStackTrace = 1;
						sRawAllocData.mType = typeof(T);
					}
					return &sRawAllocData;
				}
			}
		}
	}

	[CRepr]
	struct VarArgs
	{
#if BF_PLATFORM_WINDOWS || BF_PLATFORM_WASM
		void* mVAList;
#else
		int[5] mVAList; // Conservative size for va_list
#endif

		[Intrinsic("va_start")]
		static extern void Start(void* vaList);
		[Intrinsic("va_end")]
		static extern void End(void* vaList);
		[Intrinsic("va_arg")]
		static extern void Arg(void* vaList, void* destPtr, int32 typeId);

		[Inline]
		public mixin Start() mut
		{
			Start(&mVAList);
		}

		[Inline]
		public mixin End() mut
		{
			End(&mVAList);
		}

		[Inline]
		public mixin Get<T>() mut
		{
			T val = ?;
			Arg(&mVAList, &val, (.)typeof(T).TypeId);
			val
		}

		public void* ToVAList() mut
		{
#if BF_PLATFORM_WINDOWS || BF_PLATFORM_WASM
			return mVAList;
#else
			return &mVAList;
#endif
		}
	}

	[AlwaysInclude]
    static class Internal
    {
		enum BfObjectFlags : uint8
		{
			None			= 0,
			Mark1			= 0x01,
			Mark2			= 0x02,
			Mark3			= 0x03,
			Allocated		= 0x04,
			StackAlloc		= 0x08,
			AppendAlloc		= 0x10,
			AllocInfo		= 0x20,
			AllocInfo_Short = 0x40,	
			Deleted			= 0x80
		};

		struct AppendAllocEntry
		{
			public enum Kind
			{
				case None;
				case Object(Object obj);
				case Raw(void* ptr, DbgRawAllocData* allocData);
			}

			public Kind mKind;
			public AppendAllocEntry* mNext;
		}

		[Intrinsic("cast")]
		public static extern Object UnsafeCastToObject(void* ptr);
		[Intrinsic("cast")]
		public static extern void* UnsafeCastToPtr(Object obj);
		[Intrinsic("memcpy")]
		public static extern void MemCpy(void* dest, void* src, int length, int32 align = 1, bool isVolatile = false);
		[Intrinsic("memmove")]
		public static extern void MemMove(void* dest, void* src, int length, int32 align = 1, bool isVolatile = false);
		[Intrinsic("memset")]
		public static extern void MemSet(void* addr, uint8 val, int length, int32 align = 1, bool isVolatile = false);
		[Intrinsic("malloc")]
		public static extern void* Malloc(int size);
		[Intrinsic("free")]
		public static extern void Free(void* ptr);
		[LinkName("malloc")]
		public static extern void* StdMalloc(int size);
		[LinkName("free")]
		public static extern void StdFree(void* ptr);
		[Intrinsic("returnaddress")]
		public static extern void* GetReturnAddress(int32 level = 0);

#if BF_PLATFORM_WASM
		static int32 sTestIdx;
		static int32 sRanTestCount;
		static int32 sErrorCount;
		class TestEntry
		{
			public String mName ~ delete _;
			public String mFilePath ~ delete _;
			public int mLine;
			public int mColumn;
			public bool mShouldFail;
			public bool mProfile;
			public bool mIgnore;
			public bool mFailed;
			public bool mExecuted;
		}
		static List<TestEntry> sTestEntries ~ DeleteContainerAndItems!(_);

		[CallingConvention(.Cdecl), LinkName("Test_Init_Wasm")]
		static void Test_Init(char8* testData)
		{
			sTestEntries = new .();

			for (var cmd in StringView(testData).Split('\n'))
			{
				List<StringView> cmdParts = scope .(cmd.Split('\t'));
				let attribs = cmdParts[1];

				TestEntry testEntry = new TestEntry();
				testEntry.mName = new String(cmdParts[0]);
				testEntry.mFilePath = new String(cmdParts[2]);
				testEntry.mLine = int32.Parse(cmdParts[3]).Get();
				testEntry.mColumn = int32.Parse(cmdParts[4]).Get();
				List<StringView> attributes = scope .(attribs.Split('\a'));
				for(var i in attributes)
				{
					if (i == "Sf")
						testEntry.mShouldFail = true;
					else if (i == "Pr")
						testEntry.mProfile = true;
					else if (i == "Ig")
						testEntry.mIgnore = true;
					else if(i.StartsWith("Name"))
					{
						testEntry.mName.Clear();
						scope String(i.Substring("Name".Length)).Escape(testEntry.mName);
					}
				}
				sTestEntries.Add(testEntry);
			}
		}

		[CallingConvention(.Cdecl), LinkName("Test_Error_Wasm")]
		static void Test_Error(char8* error)
		{
			sErrorCount++;
			Debug.WriteLine(scope $"TEST ERROR: {StringView(error)}");
		}

		[CallingConvention(.Cdecl), LinkName("Test_Write_Wasm")]
		static void Test_Write(char8* str)
		{
			Debug.Write(StringView(str));
		}

		[CallingConvention(.Cdecl), LinkName("Test_Query_Wasm")]
		static int32 Test_Query()
		{
			while (sTestIdx < sTestEntries.Count)
			{
				var testEntry = sTestEntries[sTestIdx];
				if ((testEntry.mIgnore) || (testEntry.mShouldFail))
				{
					sTestIdx++;
					continue;
				}

				Debug.WriteLine($"Test '{testEntry.mName}'");
				break;
			}

			sRanTestCount++;
			return sTestIdx++;
		}

		[CallingConvention(.Cdecl), LinkName("Test_Finish_Wasm")]
		static void Test_Finish()
		{
			sRanTestCount--;

			String completeStr = scope $"Completed {sRanTestCount} of {sTestEntries.Count} tests.'";
			Debug.WriteLine(completeStr);
			if (sErrorCount > 0)
			{
				String failStr = scope $"ERROR: Failed {sErrorCount} test{((sErrorCount != 1) ? "s" : "")}";
				Debug.WriteLine(failStr);
			}
		}
#else
		[CallingConvention(.Cdecl)]
		static extern void Test_Init(char8* testData);
		[CallingConvention(.Cdecl)]
		static extern void Test_Error(char8* error);
		[CallingConvention(.Cdecl)]
		static extern void Test_Write(char8* str);
		[CallingConvention(.Cdecl)]
		static extern int32 Test_Query();
		[CallingConvention(.Cdecl)]
		static extern void Test_Finish();
#endif

		static void* sModuleHandle;
		[AlwaysInclude]
		static void SetModuleHandle(void* handle)
		{
			sModuleHandle = handle;
		}

#if !BF_RUNTIME_DISABLE
		[CallingConvention(.Cdecl), NoReturn]
		public static extern void ThrowIndexOutOfRange(int stackOffset = 0);
		[CallingConvention(.Cdecl), NoReturn]
		public static extern void ThrowObjectNotInitialized(int stackOffset = 0);
		[CallingConvention(.Cdecl), NoReturn]
		public static extern void FatalError(String error, int stackOffset = 0);
		[CallingConvention(.Cdecl)]
		public static extern void* VirtualAlloc(int size, bool canExecute, bool canWrite);
		[CallingConvention(.Cdecl)]
		public static extern int32 CStrLen(char8* charPtr);
		[CallingConvention(.Cdecl)]
		public static extern int64 GetTickCountMicro();
		[CallingConvention(.Cdecl)]
		public static extern void BfDelegateTargetCheck(void* target);
		[CallingConvention(.Cdecl), AlwaysInclude]
		public static extern void* LoadSharedLibrary(char8* filePath);
		[AlwaysInclude, LinkName("Beef_LoadSharedLibraryInto")]
		public static void LoadSharedLibraryInto(char8* filePath, void** libDest)
		{
			if (*libDest == null)
			{
				if (Runtime.LibraryLoadCallback != null)
					*libDest = Runtime.LibraryLoadCallback(filePath);
			}
			if (*libDest == null)
			{
				*libDest = LoadSharedLibrary(filePath);
			}
		}

		[CallingConvention(.Cdecl), AlwaysInclude]
		public static extern void* GetSharedProcAddress(void* libHandle, char8* procName);
		[CallingConvention(.Cdecl), AlwaysInclude]
		public static extern void GetSharedProcAddressInto(void* libHandle, char8* procName, void** procDest);
		[CallingConvention(.Cdecl)]
		public static extern char8* GetCommandLineArgs();
		[CallingConvention(.Cdecl)]
		public static extern void ProfilerCmd(char8* str);
		[CallingConvention(.Cdecl)]
		public static extern void ReportMemory();
		[CallingConvention(.Cdecl)]
		public static extern void ObjectDynCheck(Object obj, int32 typeId, bool allowNull);
		[CallingConvention(.Cdecl)]
		public static extern void ObjectDynCheckFailed(Object obj, int32 typeId);
		[CallingConvention(.Cdecl)]
		public static extern void Dbg_ObjectCreated(Object obj, int size, ClassVData* classVData);
		[CallingConvention(.Cdecl)]
		public static extern void Dbg_ObjectCreatedEx(Object obj, int size, ClassVData* classVData, uint8 allocFlags);
		[CallingConvention(.Cdecl)]
		public static extern void Dbg_ObjectAllocated(Object obj, int size, ClassVData* classVData);
		[CallingConvention(.Cdecl)]
		public static extern void Dbg_ObjectAllocatedEx(Object obj, int size, ClassVData* classVData, uint8 allocFlags);
		[CallingConvention(.Cdecl)]
		public static extern int Dbg_PrepareStackTrace(int baseAllocSize, int maxStackTraceDepth);
		[CallingConvention(.Cdecl)]
		public static extern void Dbg_ObjectStackInit(Object object, ClassVData* classVData, int size, uint8 allocFlags);
		[CallingConvention(.Cdecl)]
		public static extern Object Dbg_ObjectAlloc(TypeInstance typeInst, int size);
		[CallingConvention(.Cdecl)]
		public static extern Object Dbg_ObjectAlloc(ClassVData* classVData, int size, int align, int maxStackTraceDepth, uint8 flags);
		[CallingConvention(.Cdecl)]
		public static extern void Dbg_ObjectPreDelete(Object obj);
		[CallingConvention(.Cdecl)]
		public static extern void Dbg_ObjectPreCustomDelete(Object obj);
		[CallingConvention(.Cdecl)]
		public static extern void Dbg_MarkObjectDeleted(Object obj);
		[CallingConvention(.Cdecl)]
		public static extern void* Dbg_RawAlloc(int size);
		[CallingConvention(.Cdecl)]
		public static extern void* Dbg_RawObjectAlloc(int size);
		[CallingConvention(.Cdecl)]
		public static extern void* Dbg_RawAlloc(int size, DbgRawAllocData* rawAllocData);
		[CallingConvention(.Cdecl)]
		public static extern void Dbg_RawFree(void* ptr);

#if BF_ENABLE_OBJECT_DEBUG_FLAGS
		static void AddAppendInfo(Object rootObj, AppendAllocEntry.Kind kind)
		{
			Compiler.Assert(sizeof(AppendAllocEntry) <= sizeof(int)*4);

			void Handle(AppendAllocEntry* headAllocEntry)
			{
				if (headAllocEntry.mKind case .None)
				{
					headAllocEntry.mKind = kind;
				}
				else
				{
					AppendAllocEntry* newAppendAllocEntry = (.)new uint8[sizeof(AppendAllocEntry)]*;
					newAppendAllocEntry.mKind = kind;
					newAppendAllocEntry.mNext = headAllocEntry.mNext;
					headAllocEntry.mNext = newAppendAllocEntry;
				}
			}

			if (rootObj.[Friend]mClassVData & (int)BfObjectFlags.AllocInfo_Short != 0)
			{
				var dbgAllocInfo = rootObj.[DisableObjectAccessChecks, Friend]mDbgAllocInfo;
				uint8 allocFlag = (.)(dbgAllocInfo >> 8);
				Debug.Assert(allocFlag == 1);
				if ((allocFlag & 1) != 0)
				{
					int allocSize = (.)(dbgAllocInfo >> 16);
					int capturedTraceCount = (uint8)(dbgAllocInfo);
					uint8* ptr = (.)Internal.UnsafeCastToPtr(rootObj);
					ptr += allocSize + capturedTraceCount * sizeof(int);
					Handle((.)ptr);
				}
			}
			else if (rootObj.[Friend]mClassVData & (int)BfObjectFlags.AllocInfo != 0)
			{
				var dbgAllocInfo = rootObj.[DisableObjectAccessChecks, Friend]mDbgAllocInfo;
				int allocSize = dbgAllocInfo;
				uint8* ptr = (.)Internal.UnsafeCastToPtr(rootObj);
				int info = *(int*)(ptr + allocSize);
				int capturedTraceCount = info >> 8;
				uint8 allocFlag = (.)info;
				Debug.Assert(allocFlag == 1);
				if ((allocFlag & 1) != 0)
				{
					ptr += allocSize + capturedTraceCount * sizeof(int) + sizeof(int);
					Handle((.)ptr);
				}
			}
		}
#endif

		public static void Dbg_ObjectAppended(Object rootObj, Object appendObj)
		{
#if BF_ENABLE_OBJECT_DEBUG_FLAGS
			AddAppendInfo(rootObj, .Object(appendObj));
#endif
		}

		public static void Dbg_RawAppended(Object rootObj, void* ptr, DbgRawAllocData* rawAllocData)
		{
#if BF_ENABLE_OBJECT_DEBUG_FLAGS
			AddAppendInfo(rootObj, .Raw(ptr, rawAllocData));
#endif
		}

		public static void Dbg_MarkAppended(Object rootObj)
		{
#if BF_ENABLE_OBJECT_DEBUG_FLAGS
			void Handle(AppendAllocEntry* checkAllocEntry)
			{
				var checkAllocEntry;
				while (checkAllocEntry != null)
				{
					switch (checkAllocEntry.mKind)
					{
					case .Object(let obj):
						obj.[Friend]GCMarkMembers();
					case .Raw(let rawPtr, let allocData):
						((function void(void*))allocData.mMarkFunc)(rawPtr);
					default:
					}

					checkAllocEntry = checkAllocEntry.mNext;
				}
			}

			if (rootObj.[DisableObjectAccessChecks, Friend]mClassVData & (int)BfObjectFlags.AllocInfo_Short != 0)
			{
				var dbgAllocInfo = rootObj.[DisableObjectAccessChecks, Friend]mDbgAllocInfo;
				uint8 allocFlag = (.)(dbgAllocInfo >> 8);
				if ((allocFlag & 1) != 0)
				{
					int allocSize = (.)(dbgAllocInfo >> 16);
					int capturedTraceCount = (uint8)(dbgAllocInfo);
					uint8* ptr = (.)Internal.UnsafeCastToPtr(rootObj);
					ptr += allocSize + capturedTraceCount * sizeof(int);
					Handle((.)ptr);
				}
			}
			else if (rootObj.[DisableObjectAccessChecks, Friend]mClassVData & (int)BfObjectFlags.AllocInfo != 0)
			{
				var dbgAllocInfo = rootObj.[DisableObjectAccessChecks, Friend]mDbgAllocInfo;
				int allocSize = dbgAllocInfo;
				uint8* ptr = (.)Internal.UnsafeCastToPtr(rootObj);
				int info = *(int*)(ptr + allocSize);
				int capturedTraceCount = info >> 8;
				uint8 allocFlag = (.)info;
				if ((allocFlag & 1) != 0)
				{
					ptr += allocSize + capturedTraceCount * sizeof(int) + sizeof(int);
					Handle((.)ptr);
				}
			}
#endif
		}

		public static void Dbg_AppendDeleted(Object rootObj, bool doChecks)
		{
#if BF_ENABLE_OBJECT_DEBUG_FLAGS
			void Handle(AppendAllocEntry* headAllocEntry)
			{
				AppendAllocEntry* checkAllocEntry = headAllocEntry;
				while (checkAllocEntry != null)
				{
					switch (checkAllocEntry.mKind)
					{
					case .Object(let obj):
						if (doChecks)
						{
#unwarn
							if (!obj.[DisableObjectAccessChecks]IsDeleted())
							{
								if (obj.GetType().HasDestructor)
									Debug.FatalError("Appended object not deleted with 'delete:append'");
							}
						}
					case .Raw(let rawPtr, let allocData):
					default:
					}

					var nextAllocEntry = checkAllocEntry.mNext;
					if (checkAllocEntry == headAllocEntry)
						*checkAllocEntry = default;
					else
						delete (uint8*)checkAllocEntry;
					checkAllocEntry = nextAllocEntry;
				}
			}

			if (rootObj.[DisableObjectAccessChecks, Friend]mClassVData & (int)BfObjectFlags.AllocInfo_Short != 0)
			{
				var dbgAllocInfo = rootObj.[DisableObjectAccessChecks, Friend]mDbgAllocInfo;
				uint8 allocFlag = (.)(dbgAllocInfo >> 8);
				if ((allocFlag & 1) != 0)
				{
					int allocSize = (.)(dbgAllocInfo >> 16);
					int capturedTraceCount = (uint8)(dbgAllocInfo);
					uint8* ptr = (.)Internal.UnsafeCastToPtr(rootObj);
					ptr += allocSize + capturedTraceCount * sizeof(int);
					Handle((.)ptr);
				}
			}
			else if (rootObj.[DisableObjectAccessChecks, Friend]mClassVData & (int)BfObjectFlags.AllocInfo != 0)
			{
				var dbgAllocInfo = rootObj.[DisableObjectAccessChecks, Friend]mDbgAllocInfo;
				int allocSize = dbgAllocInfo;
				uint8* ptr = (.)Internal.UnsafeCastToPtr(rootObj);
				int info = *(int*)(ptr + allocSize);
				int capturedTraceCount = info >> 8;
				uint8 allocFlag = (.)info;
				if ((allocFlag & 1) != 0)
				{
					ptr += allocSize + capturedTraceCount * sizeof(int) + sizeof(int);
					Handle((.)ptr);
				}
			}
#endif
		}

		[CallingConvention(.Cdecl)]
		static extern void Shutdown_Internal();

		[CallingConvention(.Cdecl), AlwaysInclude]
		static void Shutdown()
		{
			Shutdown_Internal();
			Runtime.Shutdown();
		}
	#else

		

		[NoReturn]
		static void Crash()
		{
			char8* ptr = null;
			*ptr = 'A';
		}

		[AlwaysInclude, NoReturn]
		public static void ThrowIndexOutOfRange(int stackOffset = 0)
		{
			Crash();
		}

		[AlwaysInclude, NoReturn]
		public static void ThrowObjectNotInitialized(int stackOffset = 0)
		{
			Crash();
		}

		[AlwaysInclude, NoReturn]
		public static void FatalError(String error, int stackOffset = 0)
		{
			Crash();
		}

		[AlwaysInclude]
		public static void* VirtualAlloc(int size, bool canExecute, bool canWrite)
		{
			return null;
		}

		public static int32 CStrLen(char8* charPtr)
		{
			int32 len = 0;
			while (charPtr[len] != 0)
				len++;
			return len;
		}

		public static int64 GetTickCountMicro()
		{
			return 0;
		}


		[AlwaysInclude]
		public static void BfDelegateTargetCheck(void* target)
		{

		}

		[AlwaysInclude]
		public static void* LoadSharedLibrary(char8* filePath)
		{
			return null;
		}

		[AlwaysInclude]
		public static void LoadSharedLibraryInto(char8* filePath, void** libDest)
		{

		}

		[AlwaysInclude]
		public static void* GetSharedProcAddress(void* libHandle, char8* procName)
		{
			return null;
		}

		[AlwaysInclude]
		public static void GetSharedProcAddressInto(void* libHandle, char8* procName, void** procDest)
		{

		}

		[AlwaysInclude]
		public static char8* GetCommandLineArgs()
		{
			return "";
		}

		public static void ProfilerCmd(char8* str)
		{

		}

		public static void ReportMemory()
		{

		}

		public static void ObjectDynCheck(Object obj, int32 typeId, bool allowNull)
		{

		}

		public static void ObjectDynCheckFailed(Object obj, int32 typeId)
		{

		}

		[DisableChecks, DisableObjectAccessChecks]
		public static void Dbg_ObjectCreated(Object obj, int size, ClassVData* classVData)
		{
		}

		[DisableChecks, DisableObjectAccessChecks]
		public static void Dbg_ObjectCreatedEx(Object obj, int size, ClassVData* classVData)
		{

		}

		[DisableChecks, DisableObjectAccessChecks]
		public static void Dbg_ObjectAllocated(Object obj, int size, ClassVData* classVData)
		{
#if BF_ENABLE_OBJECT_DEBUG_FLAGS
			obj.[Friend]mClassVData = (.)(void*)classVData;
			obj.[Friend]mDbgAllocInfo = (.)GetReturnAddress(0);
#else
			obj.[Friend]mClassVData = classVData;
#endif
		}

		[DisableChecks, DisableObjectAccessChecks]
		public static void Dbg_ObjectAllocatedEx(Object obj, int size, ClassVData* classVData)
		{
#if BF_ENABLE_OBJECT_DEBUG_FLAGS
			obj.[Friend]mClassVData = (.)(void*)classVData;
			obj.[Friend]mDbgAllocInfo = (.)GetReturnAddress(0);
#else
			obj.[Friend]mClassVData = classVData;
#endif
		}

		public static int Dbg_PrepareStackTrace(int baseAllocSize, int maxStackTraceDepth)
		{
			return 0;
		}

		[DisableChecks, DisableObjectAccessChecks]
		public static void Dbg_ObjectStackInit(Object obj, ClassVData* classVData, int size, uint8 allocFlags)
		{
#if BF_ENABLE_OBJECT_DEBUG_FLAGS
			obj.[Friend]mClassVData = (.)(void*)classVData;
			obj.[Friend]mClassVData |= (.)BfObjectFlags.StackAlloc;
			obj.[Friend]mDbgAllocInfo = (.)GetReturnAddress(0);
#else
			obj.[Friend]mClassVData = classVData;
#endif
		}

		public static Object Dbg_ObjectAlloc(TypeInstance typeInst, int size)
		{
			return null;
		}

		public static Object Dbg_ObjectAlloc(ClassVData* classVData, int size, int align, int maxStackTraceDepth, uint8 flags)
		{
			return null;
		}

		public static void Dbg_ObjectPreDelete(Object obj)
		{

		}

		public static void Dbg_ObjectPreCustomDelete(Object obj)
		{

		}

		public static void Dbg_MarkObjectDeleted(Object obj)
		{
#if BF_ENABLE_OBJECT_DEBUG_FLAGS
			obj.[Friend]mClassVData |= (.)BfObjectFlags.Deleted;
#endif
		}

		public static void* Dbg_RawAlloc(int size)
		{
			return null;
		}

		public static void* Dbg_RawObjectAlloc(int size)
		{
			return null;
		}

		public static void* Dbg_RawAlloc(int size, DbgRawAllocData* rawAllocData)
		{
			return null;
		}

		public static void Dbg_RawFree(void* ptr)
		{

		}

		[AlwaysInclude]
		static void Shutdown()
		{

		}
	#endif

		[AlwaysInclude]
		static void AddRtFlags(int32 flags)
		{
			Runtime.[Friend]sExtraFlags |= (.)flags;
		}

		public static T* AllocRawArrayUnmarked<T>(int size)
		{
#if BF_ENABLE_REALTIME_LEAK_CHECK
			if (Compiler.IsComptime)
				return new T[size]*(?);
			// We don't want to use the default mark function because the GC will mark the entire array,
			//  whereas we have a custom marking routine because we only want to mark up to mSize
			return (T*)Internal.Dbg_RawAlloc(size * strideof(T), DbgRawAllocData.Unmarked<T>.Data);
#else
			return new T[size]*(?);
#endif
		}

		public static Object ObjectAlloc(TypeInstance typeInst, int size)
		{
#if BF_ENABLE_OBJECT_DEBUG_FLAGS
			return Dbg_ObjectAlloc(typeInst, size);
#else
			void* ptr = Malloc(size);
			return *(Object*)(&ptr);
#endif
		}

		[Error("Cannot be called directly"), SkipCall]
		static void SetDeleted1(void* dest);
		[Error("Cannot be called directly"), SkipCall]
		static void SetDeleted4(void* dest);
		[Error("Cannot be called directly"), SkipCall]
		static void SetDeleted8(void* dest);
		[Error("Cannot be called directly"), SkipCall]
		static void SetDeleted16(void* dest);
		[Error("Cannot be called directly"), SkipCall]
		static extern void SetDeletedX(void* dest, int size);
		[Error("Cannot be called directly"), SkipCall]
		static extern void SetDeleted(void* dest, int size, int32 align);
		[Error("Cannot be called directly"), SkipCall]
		static extern void SetDeletedArray(void* dest, int size, int32 align, int arrayCount);

		public static int MemCmp(void* memA, void* memB, int length)
		{
			uint8* p0 = (uint8*)memA;
			uint8* p1 = (uint8*)memB;

			uint8* end0 = p0 + length;
			while (p0 < end0)
			{
				int diff = *(p0++) - *(p1++);
				if (diff != 0)
					return diff;
			}
			return 0;
		}

		[Inline]
		public static int GetArraySize<T>(int length)
		{
			if (sizeof(T) == strideof(T))
			{
				return length * sizeof(T);
			}
			else
			{
				int size = strideof(T) * (length - 1) + sizeof(T);
				if (size < 0)
					return 0;
				return size;
			}
		}

        public static String[] CreateParamsArray()
		{
#if !BF_RUNTIME_DISABLE
			char8* cmdLine = GetCommandLineArgs();
			//Windows.MessageBoxA(default, scope String()..AppendF("CmdLine: {0}", StringView(cmdLine)), "HI", 0);

			String[] strVals = null;
			for (int pass = 0; pass < 2; pass++)
			{
				int argIdx = 0;

				void HandleArg(int idx, int len)
				{
					if (pass == 1)
					{
						var str = new String(len);
						char8* outStart = str.Ptr;
						char8* outPtr = outStart;
						bool inQuote = false;

						for (int i < len)
						{
							char8 c = cmdLine[idx + i];

							if (!inQuote)
							{
								if (c == '"')
								{
									inQuote = true;
									continue;
								}
							}
							else
							{
								if (c == '^')
								{
									i++;
									c = cmdLine[idx + i];
								}
								else if (c == '\"')
								{
									if (cmdLine[idx + i + 1] == '\"')
									{
										*(outPtr++) = '\"';
										i++;
										continue;
									}
									inQuote = false;
									continue;
								}
							}

							*(outPtr++) = c;
						}
						str.[Friend]mLength = (.)(outPtr - outStart);
						strVals[argIdx] = str;
					}

					++argIdx;
				}

				int firstCharIdx = -1;
				bool inQuote = false;
				int i = 0;
				while (true)
				{
				    char8 c = cmdLine[i];
					if (c == 0)
						break;
				    if ((c.IsWhiteSpace) && (!inQuote))
				    {
				        if (firstCharIdx != -1)
				        {
				            HandleArg(firstCharIdx, i - firstCharIdx);
				            firstCharIdx = -1;
				        }
				    }
				    else
				    {
				        if (firstCharIdx == -1)
				            firstCharIdx = i;
						if (c == '^')
						{
							i++;
						}
				        if (c == '"')
				            inQuote = !inQuote;
				        else if ((inQuote) && (c == '\\'))
						{
				            c = cmdLine[i + 1];
							if (c == '"')
								i++;
						}
				    }
					i++;
				}
				if (firstCharIdx != -1)
					HandleArg(firstCharIdx, i - firstCharIdx);
				if (pass == 0)
					strVals = new String[argIdx];
			}

		    return strVals;
#else
			return new String[0];
#endif
		}

        public static void DeleteStringArray(String[] arr)
        {
            for (var str in arr)
                delete str;
            delete arr;
        }

#if !BF_RUNTIME_DISABLE
        extern static this();
        extern static ~this();
#endif
    }

	struct CRTAlloc
	{
		public void* Alloc(int size, int align)
		{
			return Internal.StdMalloc(size);
		}

		public void Free(void* ptr)
		{
			Internal.StdFree(ptr);
		}
	}

	static
	{
		public static CRTAlloc gCRTAlloc;
	}
}

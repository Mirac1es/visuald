// This file is part of Visual D
//
// Visual D integrates the D programming language into Visual Studio
// Copyright (c) 2012 by Rainer Schuetze, All Rights Reserved
//
// Distributed under the Boost Software License, Version 1.0.
// See accompanying file LICENSE_1_0.txt or copy at http://www.boost.org/LICENSE_1_0.txt

module vdc.dmdserver.dmdserver;
import vdc.dmdserver.semvisitor;

version(MAIN) {} else version = noServer;

version(noServer):
import vdc.ivdserver;
import vdc.semanticopt;

import dmd.apply;
import dmd.arraytypes;
import dmd.builtin;
import dmd.cond;
import dmd.console;
import dmd.ctfeexpr;
import dmd.dclass;
import dmd.declaration;
import dmd.dimport;
import dmd.dinterpret;
import dmd.dmodule;
import dmd.dscope;
import dmd.dstruct;
import dmd.dsymbol;
import dmd.dsymbolsem;
import dmd.dtemplate;
import dmd.errors;
import dmd.expression;
import dmd.func;
import dmd.globals;
import dmd.hdrgen;
import dmd.id;
import dmd.identifier;
import dmd.init;
import dmd.mtype;
import dmd.objc;
import dmd.sapply;
import dmd.semantic2;
import dmd.semantic3;
import dmd.statement;
import dmd.target;
import dmd.tokens;
import dmd.visitor;

import dmd.root.outbuffer;
import dmd.root.file;
import dmd.root.filename;
import dmd.root.rmem;
import dmd.root.rootobject;

//import vdc.util;
struct TextPos
{
	int index;
	int line;
}
struct TextSpan
{
	TextPos start;
	TextPos end;
}

import sdk.port.base;
import sdk.win32.oaidl;
import sdk.win32.objbase;
import sdk.win32.oleauto;

import stdext.com;
import stdext.string;
import stdext.array;
import stdext.path;

version = SingleThread;

//import std.stdio;
import std.ascii;
import std.parallelism;
import std.path;
import std.string;
import std.conv;
import std.array;

import std.concurrency;
import std.datetime;
import core.exception;
import core.memory;
import core.thread;
import core.time;
import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;

// version = traceGC;
version (traceGC) import tracegc;

version = DebugServer;
//debug version = vdlog; // log through visual D logging (needs version = InProc in vdserverclient)

shared(Object) gDMDSync = new Object; // no multi-instances/multi-threading with DMD
shared(Object) gOptSync = new Object; // no multi-instances/multi-threading with DMD

version (traceGC)
	extern(C) __gshared string[] rt_options = [ "scanDataSeg=precise", "gcopt=gc:trace" ];
else
	// precise GC doesn't help much because dmd erases most type info
	extern(C) __gshared string[] rt_options = [ "scanDataSeg=precise", "gcopt=gc:precise" ];

///////////////////////////////////////////////////////////////////////
version(DebugServer)
{
	import std.windows.charset;
	import std.datetime;
	version(vdlog) debug import visuald.logutil;
	import core.stdc.stdio : fprintf, fopen, fputc, fflush, FILE;
	__gshared FILE* dbgfh;

	void dbglog(const(char)[] s)
	{
		debug
		{
			version(vdlog)
				logCall("DMDServer: ", s);
			else
				sdk.win32.winbase.OutputDebugStringA(toMBSz("DMDServer: " ~ s ~ "\n"));
		}
		else
		{
			if(!dbgfh)
				dbgfh = fopen("c:/tmp/dmdserver.log", "w");

			SysTime now = Clock.currTime();
			uint tid = sdk.win32.winbase.GetCurrentThreadId();
			auto len = fprintf(dbgfh, "%02d:%02d:%02d - %04x - ",
							   now.hour, now.minute, now.second, tid);
			fprintf(dbgfh, "%.*s", s.length, s.ptr);
			fputc('\n', dbgfh);
			fflush(dbgfh);
		}
	}
}

alias object.AssociativeArray!(string, std.concurrency.Tid) _wa1; // fully instantiate type info for string[Tid]
alias object.AssociativeArray!(std.concurrency.Tid, string[]) _wa2; // fully instantiate type info for string[Tid]

///////////////////////////////////////////////////////////////
enum ModuleState
{
	New,
	Pending,
	Parsing,
	Analyzing,
	Done
}

struct ModuleData
{
	string filename;
	Module parsedModule;
	Module analyzedModule;

	ModuleState state;
	string parseErrors;
	string analyzeErrors;
}

///////////////////////////////////////////////////////////////

struct delegate_fake
{
	ptrdiff_t ptr;
	ptrdiff_t context;
}

class DMDServer : ComObject, IVDServer
{
	this()
	{
		version(unittest) {} else
			version(SingleThread) mTid = spawn(&taskLoop, thisTid);
		mOptions = new Options;
		dmdInit();
	}

	override ULONG Release()
	{
		if(count == 1 && mTid != mTid.init)
		{
			// avoid recursive calls if the object is temporarily ref-counted
			// while executing Dispose()
			count = 0x12345678;

			send(mTid, "stop");
			receive((string val) { assert(val == "done"); });

			assert(count == 0x12345678);
			count = 1;
		}
		return super.Release();
	}

	override HRESULT QueryInterface(in IID* riid, void** pvObject)
	{
//		MessageBoxW(null, "Object1.QueryInterface"w.ptr, "[LOCAL] message", MB_OK|MB_SETFOREGROUND);
		if(queryInterface!(IVDServer) (this, riid, pvObject))
			return S_OK;
		return super.QueryInterface(riid, pvObject);
	}

	extern(D) static void taskLoop(Tid tid)
	{
		bool cont = true;
		while(cont)
		{
			try
			{
				receiveTimeout(dur!"msecs"(50),
							   (delegate_fake dg_fake)
							   {
								void delegate() dg = *(cast(void delegate()*)&dg_fake);
								dg();
							   },
							   (string cmd)
							   {
								if(cmd == "stop")
									cont = false;
							   },
							   (Variant var)
							   {
								var = var;
							   }
							   );
			}
			catch(OutOfMemoryError e)
			{
				exit(7); // terminate
			}
			catch(Throwable e)
			{
				version(DebugCmd) dbglog ("taskLoop exception: " ~ e.msg);
			}
		}
		prioritySend(tid, "done");
	}

	extern(D) void schedule(void delegate() dg)
	{
		version(unittest)
			dg();
		else version(SingleThread)
			send(mTid, *cast(delegate_fake*)&dg);
		else
			runTask(dg);
	}

	override HRESULT ConfigureSemanticProject(in BSTR filename, in BSTR imp, in BSTR stringImp, in BSTR versionids, in BSTR debugids, DWORD flags)
	{
		string fname = to_string(filename);

		synchronized(gOptSync)
		{
			auto opts = mOptions;

			string imports = to_string(imp);
			string strImports = to_string(stringImp);

			uint oldflags = ConfigureFlags!()(opts.unittestOn, opts.debugOn, opts.x64,
											  opts.coverage, opts.doDoc, opts.noBoundsCheck, opts.gdcCompiler,
											  0, 0, // no need to compare version levels, done in setVersionIds
											  opts.noDeprecated, opts.ldcCompiler, opts.msvcrt,
											  opts.mixinAnalysis, opts.UFCSExpansions);

			opts.unittestOn     = (flags & 1) != 0;
			opts.debugOn        = (flags & 2) != 0;
			opts.x64            = (flags & 4) != 0;
			opts.coverage       = (flags & 8) != 0;
			opts.doDoc          = (flags & 16) != 0;
			opts.noBoundsCheck  = (flags & 32) != 0;
			opts.gdcCompiler    = (flags & 64) != 0;
			opts.noDeprecated   = (flags & 128) != 0;
			opts.mixinAnalysis  = (flags & 0x1_00_00_00) != 0;
			opts.UFCSExpansions = (flags & 0x2_00_00_00) != 0;
			opts.ldcCompiler    = (flags & 0x4_00_00_00) != 0;
			opts.msvcrt         = (flags & 0x8_00_00_00) != 0;

			int versionlevel = (flags >> 8)  & 0xff;
			int debuglevel   = (flags >> 16) & 0xff;

			string verids = to_string(versionids);
			string dbgids = to_string(debugids);

			int changed = (oldflags != (flags & 0xff0000ff));
			changed += opts.setImportDirs(splitLines(imports));
			changed += opts.setStringImportDirs(splitLines(strImports));
			changed += opts.setVersionIds(versionlevel, splitLines(verids));
			changed += opts.setDebugIds(debuglevel, splitLines(dbgids));
		}
		return S_OK;
	}

	override HRESULT ClearSemanticProject()
	{
		/+
		synchronized(mSemanticProject)
			mSemanticProject.disconnectAll();

		mSemanticProject = new vdc.semantic.Project;
		mSemanticProject.saveErrors = true;
		+/
		return S_OK;
	}

	override HRESULT UpdateModule(in BSTR filename, in BSTR srcText, in DWORD flags)
	{
		string fname = makeFilenameCanonical(to_string(filename), null);
		size_t len = wcslen(srcText);
		string text  = to_string(srcText, len + 1); // DMD parser needs trailing 0
		text = text[0..$-1];

		ModuleData* modData;
		bool doCancel = false;
		synchronized(gErrorSync)
		{
			// cancel existing
			modData = findModule(fname, false);
			if (modData)
			{
				if (modData.state == ModuleState.Parsing || modData.state == ModuleState.Analyzing)
					doCancel = true;
			}

			// always create new module
			modData = findModule(fname, true);
			modData.state = ModuleState.Pending;
		}
		if (doCancel)
		{
			Mem.cancel = true;
			synchronized(gDMDSync)
			{
				// wait for parsing done
				Mem.cancel = false;
			}
		}

		void doParse()
		{
			version(DebugServer) dbglog("    doParse: " ~ firstLine(text));

			synchronized(gErrorSync)
			{
				modData.state = ModuleState.Parsing;
			}
			synchronized(gDMDSync)
			{
				try
				{
					initErrorFile(fname);
					parseModule(modData, text);
				}
				catch(OutOfMemoryError e)
				{
					throw e; // terminate
				}
				catch(Throwable t)
				{
					version(DebugServer) dbglog("UpdateModule.doParse: exception " ~ t.msg);
				}
				synchronized(gErrorSync)
				{
					modData.parseErrors = cast(string) gErrorMessages;
				}

				modData.state = ModuleState.Analyzing;
				try
				{
					initErrorFile(fname);
					// clear all other semantic modules?
					analyzeModules(modData);
				}
				catch(OutOfMemoryError e)
				{
					throw e; // terminate
				}
				catch(Throwable t)
				{
					version(DebugServer) dbglog("UpdateModule.doParse: exception " ~ t.msg);
				}
				synchronized(gErrorSync)
				{
					modData.analyzeErrors = cast(string) gErrorMessages;
				}
				modData.state = ModuleState.Done;
			}

			if(flags & 1)
				writeReadyMessage();
		}
		version(DebugServer) dbglog("  scheduleParse: " ~ firstLine(text));
		schedule(&doParse);
		return S_OK;
	}

	override HRESULT GetParseErrors(in BSTR filename, BSTR* errors)
	{
		string fname = makeFilenameCanonical(to_string(filename), null);

		if(auto md = findModule(fname, false))
		{
			synchronized(gErrorSync)
			{
				if (md.state == ModuleState.Done)
				{
					string err = md.parseErrors ~ md.analyzeErrors;
					version(DebugServer)
						dbglog("GetParseErrors: " ~ err);

					*errors = allocBSTR(err);
					return S_OK;
				}
			}
		}
		return S_FALSE;
	}

	override HRESULT GetTip(in BSTR filename, int startLine, int startIndex, int endLine, int endIndex, int flags)
	{
		string fname = makeFilenameCanonical(to_string(filename), null);

		mTipSpan.start.line  = startLine;
		mTipSpan.start.index = startIndex;
		mTipSpan.end.line    = endLine;
		mTipSpan.end.index   = endIndex;

		ModuleData* md;
		synchronized(gErrorSync)
		{
			md = findModule(fname, false);
			if (!md)
				return S_FALSE;
		}

		void _getTip()
		{
			string txt;
			synchronized(gDMDSync)
			{
				try
				{
					if (auto m = md.analyzedModule)
						txt = findTip(m, startLine, startIndex + 1, endLine, endIndex + 1);
					else
						txt = "analyzing...";
				}
				catch(OutOfMemoryError e)
				{
					throw e; // terminate
				}
				catch(Throwable t)
				{
					version(DebugServer) dbglog("GetTip: exception " ~ t.msg);
					txt = "exception: " ~ t.msg;
				}
			}
			mLastTip = txt;
			mSemanticTipRunning = false;
		}
		version(DebugServer) dbglog("  schedule GetTip: " ~ fname);
		mSemanticTipRunning = true;
		schedule(&_getTip);

		return S_OK;
	}

	override HRESULT GetTipResult(ref int startLine, ref int startIndex, ref int endLine, ref int endIndex, BSTR* answer)
	{
		if(mSemanticTipRunning)
		{
			*answer = allocBSTR("__pending__");
			return S_OK;
		}

		version(DebugServer) dbglog("GetTipResult: " ~ mLastTip);
		writeReadyMessage();
		startLine  = mTipSpan.start.line;
		startIndex = mTipSpan.start.index;
		endLine    = mTipSpan.end.line;
		endIndex   = mTipSpan.end.index;
		*answer = allocBSTR(mLastTip);
		return S_OK;
	}

	override HRESULT GetDefinition(in BSTR filename, int startLine, int startIndex, int endLine, int endIndex)
	{
		string fname = makeFilenameCanonical(to_string(filename), null);

		mDefSpan.start.line  = startLine;
		mDefSpan.start.index = startIndex + 1;
		mDefSpan.end.line    = endLine;
		mDefSpan.end.index   = endIndex + 1;

		ModuleData* md;
		synchronized(gErrorSync)
		{
			md = findModule(fname, false);
			if (!md)
				return S_FALSE;
		}

		void _getDefinition()
		{
			string deffilename;
			synchronized(gDMDSync)
			{
				try
				{
					if (auto m = md.analyzedModule)
						deffilename = findDefinition(m, mDefSpan.start.line, mDefSpan.start.index);
					else
						deffilename = "analyzing...";
				}
				catch(OutOfMemoryError e)
				{
					throw e; // terminate
				}
				catch(Throwable t)
				{
					version(DebugServer) dbglog("GetDefinition: exception " ~ t.msg);
				}
			}
			mLastDefFile = deffilename;
			mSemanticDefinitionRunning = false;
		}
		version(DebugServer) dbglog("  schedule GetDefinition: " ~ fname);
		mSemanticDefinitionRunning = true;
		schedule(&_getDefinition);

		return S_OK;
	}

	override HRESULT GetDefinitionResult(ref int startLine, ref int startIndex, ref int endLine, ref int endIndex, BSTR* answer)
	{
		if(mSemanticDefinitionRunning)
		{
			*answer = allocBSTR("__pending__");
			return S_OK;
		}

		version(DebugServer) dbglog("GetDefinitionResult: " ~ mLastDefFile);
		writeReadyMessage();
		startLine  = mDefSpan.start.line;
		startIndex = mDefSpan.start.index - 1;
		endLine    = mDefSpan.start.line;
		endIndex   = mDefSpan.start.index;
		*answer = allocBSTR(mLastDefFile);
		return S_OK;
	}

	override HRESULT GetSemanticExpansions(in BSTR filename, in BSTR tok, uint line, uint idx, in BSTR expr)
	{
		string fname = makeFilenameCanonical(to_string(filename), null);

		ModuleData* md;
		synchronized(gErrorSync)
		{
			md = findModule(fname, false);
			if (!md)
				return S_FALSE;
		}

		string stok = to_string(tok);
		string sexpr = to_string(expr);
		void _calcExpansions()
		{
			string[] symbols;
			try
			{
				if (auto m = md.analyzedModule)
					symbols = findExpansions(m, line, idx + 1, stok);
			}
			catch(OutOfMemoryError e)
			{
				throw e; // terminate
			}
			catch(Throwable t)
			{
				version(DebugServer) dbglog("calcExpansions: exception " ~ t.msg);
			}
			mSemanticExpansionsRunning = false;
			mLastSymbols = symbols;
		}
		version(DebugServer) dbglog("  schedule GetSemanticExpansions: " ~ fname);
		mLastSymbols = null;
		mSemanticExpansionsRunning = true;
		schedule(&_calcExpansions);

		return S_OK;
	}

	override HRESULT GetSemanticExpansionsResult(BSTR* stringList)
	{
		if(mSemanticExpansionsRunning)
			return S_FALSE;

		Appender!string slist;
		foreach(sym; mLastSymbols)
		{
			slist.put(sym);
			slist.put('\n');
		}
		*stringList = allocBSTR(slist.data);

		version(DebugServer) dbglog("GetSemanticExpansionsResult: " ~ slist.data);
		writeReadyMessage();
		return S_OK;
	}

	// obsolete, implement GetBinaryIsInLocations
	override HRESULT IsBinaryOperator(in BSTR filename, uint startLine, uint startIndex, uint endLine, uint endIndex, BOOL* pIsOp)
	{
		if(!pIsOp)
			return E_POINTER;

		*pIsOp = false;
		return S_OK;
	}

	override HRESULT ConfigureCommentTasks(in BSTR tasks)
	{
		return E_NOTIMPL;
	}

	override HRESULT GetCommentTasks(in BSTR filename, BSTR* tasks)
	{
		return E_NOTIMPL;
	}

	override HRESULT GetBinaryIsInLocations(in BSTR filename, VARIANT* locs)
	{
		// array of pairs of DWORD
		string fname = makeFilenameCanonical(to_string(filename), null);

		ModuleData* md;
		synchronized(gErrorSync)
		{
			md = findModule(fname, false);
			if (!md || !md.parsedModule)
				return S_FALSE;
		}

		int[] locData = findBinaryIsInLocations(md.parsedModule);

		SAFEARRAY *sa = SafeArrayCreateVector(VT_INT, 0, cast(ULONG) locData.length);
		if(!sa)
			return E_OUTOFMEMORY;

		for(LONG index = 0; index < locData.length; index++)
			SafeArrayPutElement(sa, &index, &locData[index]);

		locs.vt = VT_ARRAY | VT_INT;
		locs.parray = sa;
		return S_OK;
	}

	override HRESULT GetLastMessage(BSTR* message)
	{
		if(!mLastMessage.length)
		{
			if(mNextReadyMessage > Clock.currTime())
				return S_FALSE;

			mLastMessage = "Ready";
			mNextReadyMessage = Clock.currTime().add!"years"(1);
		}
		*message = allocBSTR(mLastMessage);
		mLastMessage = null;
		return S_OK;
	}

	override HRESULT GetReferences(in BSTR filename, in BSTR tok, uint line, uint idx, in BSTR expr, in BOOL moduleOnly)
	{
		string fname = makeFilenameCanonical(to_string(filename), null);

		ModuleData* md;
		synchronized(gErrorSync)
		{
			md = findModule(fname, false);
			if (!md)
				return S_FALSE;
		}

		void _getReferences()
		{
			string references;
			synchronized(gDMDSync)
			{
				try
				{
					if (auto m = md.analyzedModule)
						references = findReferences(m, line, idx + 1);
					else
						references = "analyzing...";
				}
				catch(OutOfMemoryError e)
				{
					throw e; // terminate
				}
				catch(Throwable t)
				{
					version(DebugServer) dbglog("GetReferences: exception " ~ t.msg);
				}
			}
			mLastReferences = references;
			mSemanticGetReferencesRunning = false;
		}
		version(DebugServer) dbglog("  schedule GetReferences: " ~ fname);
		mSemanticGetReferencesRunning = true;
		schedule(&_getReferences);

		return S_OK;
	}

	override HRESULT GetReferencesResult(BSTR* stringList)
	{
		if(mSemanticGetReferencesRunning)
		{
			*stringList = allocBSTR("__pending__");
			return S_OK;
		}
		*stringList = allocBSTR(mLastReferences);
		return S_OK;
	}

	HRESULT GetIdentifierTypes(in BSTR filename, int startLine, int endLine, int flags)
	{
		string fname = makeFilenameCanonical(to_string(filename), null);

		mIdTypesSpan.start.line  = startLine; // unused so far
		mIdTypesSpan.start.index = 0;
		mIdTypesSpan.end.line    = endLine;
		mIdTypesSpan.end.index   = 0;

		ModuleData* md;
		synchronized(gErrorSync)
		{
			md = findModule(fname, false);
			if (!md)
				return S_FALSE;
		}

		void _getIdentifierTypes()
		{
			string identiferTypes;
			synchronized(gDMDSync)
			{
				try
				{
					if (auto m = md.analyzedModule)
						identiferTypes = findIdentifierTypes(m);
					else
						identiferTypes = "identifying...";
				}
				catch(OutOfMemoryError e)
				{
					throw e; // terminate
				}
				catch(Throwable t)
				{
					version(DebugServer) dbglog("GetIdentifierTypes: exception " ~ t.msg);
				}
			}
			mLastIdentifierTypes = identiferTypes;
			mSemanticIdentifierTypesRunning = false;
		}
		version(DebugServer) dbglog("  schedule GetIdentifierTypes: " ~ fname);
		mSemanticIdentifierTypesRunning = true;
		schedule(&_getIdentifierTypes);

		return S_OK;
	}

	HRESULT GetIdentifierTypesResult(BSTR* types)
	{
		if(mSemanticIdentifierTypesRunning)
		{
			*types = allocBSTR("__pending__");
			return S_OK;
		}
		*types = allocBSTR(mLastIdentifierTypes);
		return S_OK;
	}

	///////////////////////////////////////////////////////////////
	// create our own task pool to be able to destroy it (it keeps a the
	//  arguments to the last task, so they are never collected)
	__gshared TaskPool parseTaskPool;

	void runTask(T)(T dg)
	{
		if(!parseTaskPool)
		{
			int threads = defaultPoolThreads;
			if(threads < 1)
				threads = 1;
			parseTaskPool = new TaskPool(threads);
			parseTaskPool.isDaemon = true;
			parseTaskPool.priority(core.thread.Thread.PRIORITY_MIN);
		}
		auto task = task(dg);
		parseTaskPool.put(task);
	}

	void writeReadyMessage()
	{
		if(mHadMessage)
		{
			mNextReadyMessage = Clock.currTime() + dur!"seconds"(2);
			mHadMessage = false;
		}
	}

	void parseModule(ModuleData* md, string text)
	{
		string name = stripExtension(baseName(md.filename));
		auto id = Identifier.idPool(name);
		md.parsedModule = new Module(md.filename, id, false, false);
		md.parsedModule.srcBuffer = new FileBuffer(cast(ubyte[])text);
		md.parsedModule.read(Loc.initial);
		md.parsedModule.parse();
	}

	void analyzeModules(ModuleData* rootModule)
	{
		version(none)
		{
		clearDmdStatics();

		// (de-)initialization
		Type.deinitialize();
		//Id.deinitialize();
		Module.deinitialize();
		target.deinitialize();
		Expression.deinitialize();
		Objc.deinitialize();
		builtinDeinitialize();
		Token._init();
		Module._init();
		}

		Module.rootModule = null;
		global = global.init;

		version(DebugServer)
		{
			core.memory.GC.Stats stats = GC.stats();
			dbglog(text("before collect GC stats: ", stats.usedSize, " used, ", stats.freeSize, " free\n"));
		}

		version(traceGC)
		{
			wipeStack();
			GC.collect();
			dumpGC();
		}
		else
		{
			GC.collect();
		}

		version(DebugServer)
		{
			stats = GC.stats();
			dbglog(text("after  collect GC stats: ", stats.usedSize, " used, ", stats.freeSize, " free\n"));
		}

		synchronized(gOptSync)
		{
			global._init();
			global.params.isWindows = true;
			global.params.errorLimit = 0;
			global.params.color = false;
			global.params.link = true;
			global.params.useAssert = mOptions.debugOn ? CHECKENABLE.on : CHECKENABLE.off;
			global.params.useInvariants = mOptions.debugOn ? CHECKENABLE.on : CHECKENABLE.off;
			global.params.useIn = mOptions.debugOn ? CHECKENABLE.on : CHECKENABLE.off;
			global.params.useOut = mOptions.debugOn ? CHECKENABLE.on : CHECKENABLE.off;
			global.params.useArrayBounds = mOptions.noBoundsCheck ? CHECKENABLE.on : CHECKENABLE.off; // set correct value later
			global.params.doDocComments = mOptions.doDoc;
			global.params.useSwitchError = CHECKENABLE.on;
			global.params.useInline = false;
			global.params.obj = false;
			global.params.useDeprecated = mOptions.noDeprecated ? DiagnosticReporting.error : DiagnosticReporting.off;
			global.params.linkswitches = Strings();
			global.params.libfiles = Strings();
			global.params.dllfiles = Strings();
			global.params.objfiles = Strings();
			global.params.ddocfiles = Strings();
			// Default to -m32 for 32 bit dmd, -m64 for 64 bit dmd
			global.params.is64bit = mOptions.x64;
			global.params.mscoff = mOptions.msvcrt;
			global.params.cpu = CPU.baseline;
			global.params.isLP64 = global.params.is64bit;

			global.params.versionlevel = mOptions.versionIds.level;
			global.params.versionids = new Strings();
			foreach(id, v; mOptions.versionIds.identifiers)
				global.params.versionids.push(toStringz(id));

			global.versionids = new Identifiers();

			// Add in command line versions
			if (global.params.versionids)
				foreach (charz; *global.params.versionids)
				{
					auto ident = charz[0 .. strlen(charz)];
					if (VersionCondition.isReserved(ident))
						VersionCondition.addPredefinedGlobalIdent(ident);
					else
						VersionCondition.addGlobalIdent(ident);
				}

			if (mPredefineVersions)
			{
				VersionCondition.addPredefinedGlobalIdent("DigitalMars");
				VersionCondition.addPredefinedGlobalIdent("Windows");
				VersionCondition.addPredefinedGlobalIdent("LittleEndian");
				VersionCondition.addPredefinedGlobalIdent("D_Version2");
				VersionCondition.addPredefinedGlobalIdent("all");
				if (global.params.is64bit)
				{
					VersionCondition.addPredefinedGlobalIdent("D_InlineAsm_X86_64");
					VersionCondition.addPredefinedGlobalIdent("X86_64");
					VersionCondition.addPredefinedGlobalIdent("Win64");
				}
				else
				{
					VersionCondition.addPredefinedGlobalIdent("D_InlineAsm"); //legacy
					VersionCondition.addPredefinedGlobalIdent("D_InlineAsm_X86");
					VersionCondition.addPredefinedGlobalIdent("X86");
					VersionCondition.addPredefinedGlobalIdent("Win32");
				}
				if (global.params.mscoff || global.params.is64bit)
					VersionCondition.addPredefinedGlobalIdent("CRuntime_Microsoft");
				else
					VersionCondition.addPredefinedGlobalIdent("CRuntime_DigitalMars");
				if (global.params.isLP64)
					VersionCondition.addPredefinedGlobalIdent("D_LP64");
				if (global.params.doDocComments)
					VersionCondition.addPredefinedGlobalIdent("D_Ddoc");
				if (global.params.cov)
					VersionCondition.addPredefinedGlobalIdent("D_Coverage");
				if (global.params.pic)
					VersionCondition.addPredefinedGlobalIdent("D_PIC");
				if (global.params.useUnitTests)
					VersionCondition.addPredefinedGlobalIdent("unittest");
				if (global.params.useAssert)
					VersionCondition.addPredefinedGlobalIdent("assert");
				if (global.params.useArrayBounds == CHECKENABLE.off)
					VersionCondition.addPredefinedGlobalIdent("D_NoBoundsChecks");
				if (global.params.betterC)
					VersionCondition.addPredefinedGlobalIdent("D_betterC");
			}

			// always enable for tooltips
			global.params.doDocComments = true;

			global.params.debugids = new Strings();
			global.params.debuglevel = mOptions.debugIds.level;
			foreach(id, v; mOptions.debugIds.identifiers)
				global.params.debugids.push(toStringz(id));

			global.debugids = new Identifiers();
			if (global.params.debugids)
				foreach (charz; *global.params.debugids)
					DebugCondition.addGlobalIdent(charz[0 .. strlen(charz)]);

			global.path = new Strings();
			foreach(i; mOptions.importDirs)
				global.path.push(toStringz(i));

			global.filePath = new Strings();
			foreach(i; mOptions.stringImportDirs)
				global.filePath.push(toStringz(i));
		}

		dmdReinit(true);

		for (size_t i = 0; i < mModules.length; i++)
		{
			ModuleData* md = mModules[i];
			Module m = cloneModule(md.parsedModule);
			m.importedFrom = m;
			m = m.resolvePackage();
			md.analyzedModule = m;
			Module.modules.insert(m);
		}
		Module.rootModule = rootModule.analyzedModule;
		Module.loadModuleHandler = (const ref Loc location, Identifiers* packages, Identifier ident)
		{
			return Module.loadFromFile(location, packages, ident);
		};

		for (size_t i = 0; i < mModules.length; i++)
		{
			Module m = mModules[i].analyzedModule;
			m.importAll(null);
		}

version(all)
{
		Module.rootModule.dsymbolSemantic(null);
		Module.dprogress = 1;
		Module.runDeferredSemantic();
		Module.rootModule.semantic2(null);
		Module.runDeferredSemantic2();
		Module.rootModule.semantic3(null);
		Module.runDeferredSemantic3();
}
else
{
		// Do semantic analysis
		for (size_t i = 0; i < modules.length; i++)
		{
			Module m = mModules[i].analyzedModule;
			m.dsymbolSemantic(null);
		}

		Module.dprogress = 1;
		Module.runDeferredSemantic();

		// Do pass 2 semantic analysis
		for (size_t i = 0; i < modules.length; i++)
		{
			Module m = modules[i];
			m.semantic2(null);
		}
		Module.runDeferredSemantic2();

		// Do pass 3 semantic analysis
		for (size_t i = 0; i < modules.length; i++)
		{
			Module m = modules[i];
			m.semantic3(null);
		}
		Module.runDeferredSemantic3();
}
	}

private:
	static void clearModule(Module m)
	{
		m.insearch = 0;
		m.searchCacheIdent = null;
		m.searchCacheSymbol = null;  // cached value of search
		m.searchCacheFlags = 0;      // cached flags

		m.importedFrom = null;
		m.decldefs = null;           // top level declarations for this Module
		m.aimports = Modules();      // all imported modules

		m.debuglevel = 0;            // debug level
		m.debugids = null;           // debug identifiers
		m.debugidsNot = null;        // forward referenced debug identifiers

		m.versionlevel = 0;          // version level
		m.versionids = null;         // version identifiers
		m.versionidsNot = null;      // forward referenced version identifiers

		m.macrotable = null;         // document comment macros
		m.escapetable = null;        // document comment escapes

		m._scope = null;             // !=null means context to use for semantic()
		m.prettystring = null;       // cached value of toPrettyChars()
		m.errors = 0;                // this symbol failed to pass semantic()
	}

	ModuleData* findModule(string fname, bool createNew)
	{
		size_t pos = mModules.length;
		foreach (i, m; mModules)
			if (m.filename == fname)
			{
				if (createNew)
				{
					pos = i;
					break;
				}
				return m;
			}

		if (!createNew)
			return null;

		auto md = new ModuleData;
		md.filename = fname;
		if (pos < mModules.length)
			mModules[pos] = md;
		else
			mModules ~= md;
		return md;
	}

	version(SingleThread) Tid mTid;

	Options mOptions;
	ModuleData*[] mModules;

	bool mSemanticExpansionsRunning;
	bool mSemanticTipRunning;
	bool mSemanticDefinitionRunning;
	bool mSemanticIdentifierTypesRunning;
	bool mSemanticGetReferencesRunning;

	bool mPredefineVersions;

	string mModuleToParse;
	string mLastTip;
	TextSpan mTipSpan;

	string mLastDefFile;
	TextSpan mDefSpan;

	string mLastIdentifierTypes;
	TextSpan mIdTypesSpan;

	string mLastReferences;
	string[] mLastSymbols;
	string mLastMessage;
	string mLastError;
	bool mHadMessage;
	SysTime mNextReadyMessage;
}

shared(Object) gErrorSync = new Object;
__gshared string gErrorFile;
__gshared char[] gErrorMessages;
__gshared char[] gOtherErrorMessages;
__gshared bool gErrorWasSupplemental;

void  errorPrint(const ref Loc loc, Color headerColor, const(char)* header,
				 const(char)* format, va_list ap, const(char)* p1 = null, const(char)* p2 = null) nothrow
{
	if (!loc.filename)
		return;

	import dmd.errors;

	try synchronized(gErrorSync)
	{
		bool other = _stricmp(loc.filename, gErrorFile) != 0;
		while (header && std.ascii.isWhite(*header))
			header++;
		bool supplemental = !header && !*header;

		__gshared char[4096] buf;
		int len = 0;
		if (other)
		{
			len = snprintf(buf.ptr, buf.length, "%s(%d):", loc.filename, loc.linnum);
		}
		else
		{
			int llen = snprintf(buf.ptr, buf.length, "%d,%d,%d,%d:", loc.linnum, loc.charnum - 1, loc.linnum, loc.charnum);
			gErrorMessages ~= buf[0..llen];
			if (supplemental)
				gErrorMessages ~= gOtherErrorMessages;
			gOtherErrorMessages = null;
		}
		if (p1 && len < buf.length)
			len += snprintf(buf.ptr + len, buf.length - len, "%s ", p1);
		if (p2 && len < buf.length)
			len += snprintf(buf.ptr + len, buf.length - len, "%s ", p2);
		if (len < buf.length)
			len += vsnprintf(buf.ptr + len, buf.length - len, format, ap);
		char nl = other ? '\a' : '\n';
		if (len < buf.length)
			buf[len++] = nl;
		else
			buf[$-1] = nl;

		version(DebugServer) dbglog(buf[0..len]);

		if (other)
		{
			if (gErrorWasSupplemental)
			{
				if (gErrorMessages.length && gErrorMessages[$-1] == '\n')
					gErrorMessages[$-1] = '\a';
				gErrorMessages ~= buf[0..len];
				gErrorMessages ~= '\n';
			}
			else if (supplemental)
				gOtherErrorMessages ~= buf[0..len];
			else
			{
				gErrorWasSupplemental = false;
				gOtherErrorMessages = buf[0..len].dup;
			}
		}
		else
		{
			gErrorMessages ~= buf[0..len];
			gErrorWasSupplemental = supplemental;
		}
	}
	catch(Exception e)
	{

	}
}

void initErrorFile(string fname)
{
	synchronized(gErrorSync)
	{
		gErrorFile = fname;
		gErrorMessages = null;
		gOtherErrorMessages = null;
		gErrorWasSupplemental = false;

		import std.functional;
		diagnosticHandler = toDelegate(&errorPrint);
	}
}

int _stricmp(const(char)*str1, string s2) nothrow
{
	const(char)[] s1 = str1[0..strlen(str1)];
	return icmp(s1, s2);
}

int _stricmp(const(wchar)*str1, wstring s2) nothrow
{
	const(wchar)[] s1 = str1[0..wcslen(str1)];
	return icmp(s1, s2);
}

////////////////////////////////////////////////////////////////
alias countersType = uint[uint]; // actually uint[Key]

enum string[2][] dmdStatics =
[
	["_D3dmd5clone12buildXtoHashFCQBa7dstruct17StructDeclarationPSQCg6dscope5ScopeZ8tftohashCQDh5mtype12TypeFunction", "TypeFunction"],
	["_D3dmd7dstruct15search_toStringRCQBfQBe17StructDeclarationZ10tftostringCQCs5mtype12TypeFunction", "TypeFunction"],
	["_D3dmd13expressionsem11loadStdMathFZ10impStdMathCQBv7dimport6Import", "Import"],
	["_D3dmd4func15FuncDeclaration8genCfuncRPSQBm4root5array__T5ArrayTCQCl5mtype9ParameterZQBcCQDjQy4TypeCQDu10identifier10IdentifiermZ2stCQFb7dsymbol12DsymbolTable", "DsymbolTable"],
	["_D3dmd7typesem12typeSemanticRCQBc5mtype4TypeSQBr7globals3LocPSQCi6dscope5ScopeZ11visitAArrayMFCQDpQCn10TypeAArrayZ3feqCQEn4func15FuncDeclaration", "FuncDeclaration"],
	["_D3dmd7typesem12typeSemanticRCQBc5mtype4TypeSQBr7globals3LocPSQCi6dscope5ScopeZ11visitAArrayMFCQDpQCn10TypeAArrayZ4fcmpCQEo4func15FuncDeclaration", "FuncDeclaration"],
	["_D3dmd7typesem12typeSemanticRCQBc5mtype4TypeSQBr7globals3LocPSQCi6dscope5ScopeZ11visitAArrayMFCQDpQCn10TypeAArrayZ5fhashCQEp4func15FuncDeclaration", "FuncDeclaration"],
	["_D3dmd7typesem6dotExpFCQv5mtype4TypePSQBk6dscope5ScopeCQCb10expression10ExpressionCQDdQBc8DotIdExpiZ11visitAArrayMFCQEkQDq10TypeAArrayZ8fd_aaLenCQFn4func15FuncDeclaration", "FuncDeclaration"],
	["_D3dmd7typesem6dotExpFCQv5mtype4TypePSQBk6dscope5ScopeCQCb10expression10ExpressionCQDdQBc8DotIdExpiZ8noMemberMFQDlQDaQClCQEp10identifier10IdentifieriZ4nesti", "int"],
	["_D3dmd6dmacro5Macro6expandMFPSQBc4root9outbuffer9OutBufferkPkAxaZ4nesti", "int"], // x86
	["_D3dmd7dmodule6Module19runDeferredSemanticRZ6nestedi", "int"],
	["_D3dmd10dsymbolsem22DsymbolSemanticVisitor5visitMRCQBx9dtemplate13TemplateMixinZ4nesti", "int"],
	["_D3dmd9dtemplate16TemplateInstance16tryExpandMembersMFPSQCc6dscope5ScopeZ4nesti", "int"],
	["_D3dmd9dtemplate16TemplateInstance12trySemantic3MFPSQBy6dscope5ScopeZ4nesti", "int"],
	["_D3dmd13expressionsem25ExpressionSemanticVisitor5visitMRCQCd10expression7CallExpZ4nesti", "int"],
	["_D3dmd5lexer5Lexer12stringbufferSQBf4root9outbuffer9OutBuffer", "OutBuffer"],
	["_D3dmd10expression10IntegerExp__T7literalVii0ZQnRZ11theConstantCQCkQCjQCa", "IntegerExp"],
	["_D3dmd10expression10IntegerExp__T7literalVii1ZQnRZ11theConstantCQCkQCjQCa", "IntegerExp"],
	["_D3dmd10expression10IntegerExp__T7literalViN1ZQnRZ11theConstantCQCkQCjQCa", "IntegerExp"],
	["_D3dmd10identifier10Identifier17generateIdWithLocFNbAyaKxSQCe7globals3LocZ8countersHSQDfQDeQCvQCmFNbQBwKxQBwZ3Keyk", "countersType"],
	["_D3dmd10identifier10Identifier10generateIdRNbPxaZ1im", "int"],
	["_D3dmd5lexer5Lexer4scanMFNbPSQBb6tokens5TokenZ8initdoneb", "bool"],
];

string cmangled(string s)
{
	version (Win64)
		if (s ==   "_D3dmd6dmacro5Macro6expandMFPSQBc4root9outbuffer9OutBufferkPkAxaZ4nesti")
			return "_D3dmd6dmacro5Macro6expandMFPSQBc4root9outbuffer9OutBuffermPmAxaZ4nesti";
	return s;
}

string genDeclDmdStatics()
{
	string s;
	foreach (decl; dmdStatics)
		s ~= q{extern extern(C) __gshared } ~ decl[1] ~ " " ~ cmangled(decl[0]) ~ ";\n";
	return s;
}

string genInitDmdStatics()
{
	string s;
	foreach (decl; dmdStatics)
		s ~= cmangled(decl[0]) ~ " = " ~ decl[1] ~ ".init;\n";
	return s;
}

mixin(genDeclDmdStatics);

pragma(mangle, "_D3dmd12statementsem24StatementSemanticVisitor5visitMRCQCb9statement16ForeachStatementZ7fdapplyPCQDr4func15FuncDeclaration")
extern __gshared FuncDeclaration* statementsem_fdapply;
pragma(mangle, "_D3dmd12statementsem24StatementSemanticVisitor5visitMRCQCb9statement16ForeachStatementZ6fldeTyPCQDq5mtype12TypeDelegate")
extern __gshared TypeDelegate* statementsem_fldeTy;


void clearSemanticStatics()
{
	/*
	import core.demangle;
	static foreach(s; dmdStatics)
		pragma(msg, demangle(s[0]));
	*/
	mixin(genInitDmdStatics);

	// statementsem
	// static __gshared FuncDeclaration* fdapply = [null, null];
	// static __gshared TypeDelegate* fldeTy = [null, null];
	statementsem_fdapply[0] = statementsem_fdapply[1] = null;
	statementsem_fldeTy[0]  = statementsem_fldeTy[1] = null;

	// dmd.dtemplate
	emptyArrayElement = null;
	TemplateValueParameter.edummies = null;
	TemplateTypeParameter.tdummy = null;
	TemplateAliasParameter.sdummy = null;

	CtfeStatus.callDepth = 0;
	CtfeStatus.stackTraceCallsToSuppress = 0;
	CtfeStatus.maxCallDepth = 0;
	CtfeStatus.numAssignments = 0;

	VarDeclaration.nextSequenceNumber = 0;

	// Package.this.packageTag?
	// funcDeclarationSemantic.printedMain?
/+
	Type.stringtable.reset();

	dinterpret_init();

	Scope.freelist = null;
	//Token.freelist = null;

	Identifier.initTable();
+/
}

// initialization that are necessary once
void dmdInit()
{
	__gshared bool initialized;
	if (initialized)
		return;
	initialized = true;

	import dmd.root.longdouble;
	// Initialization
	version(CRuntime_Microsoft)
		initFPU();

	global.params.isWindows = true;
	global._init();
	Token._init();
	Id.initialize();
	Expression._init();
	builtin_init();

	target._init(global.params); // needed by Type._init
	Type._init();

	dmdReinit(true);
}

// initialization that are necessary before restarting an analysis (which might run
// for another platform/architecture)
void dmdReinit(bool configChanged)
{
	if (configChanged)
	{
		target._init(global.params); // needed by Type._init
		Type._reinit();

		// assume object.d unmodified otherwis
		Module.moduleinfo = null;

		ClassDeclaration.object = null;
		ClassDeclaration.throwable = null;
		ClassDeclaration.exception = null;
		ClassDeclaration.errorException = null;
		ClassDeclaration.cpp_type_info_ptr = null;

		StructDeclaration.xerreq = null;
		StructDeclaration.xerrcmp = null;

		Type.dtypeinfo = null;
		Type.typeinfoclass = null;
		Type.typeinfointerface = null;
		Type.typeinfostruct = null;
		Type.typeinfopointer = null;
		Type.typeinfoarray = null;
		Type.typeinfostaticarray = null;
		Type.typeinfoassociativearray = null;
		Type.typeinfovector = null;
		Type.typeinfoenum = null;
		Type.typeinfofunction = null;
		Type.typeinfodelegate = null;
		Type.typeinfotypelist = null;
		Type.typeinfoconst = null;
		Type.typeinfoinvariant = null;
		Type.typeinfoshared = null;
		Type.typeinfowild = null;
		Type.rtinfo = null;
	}
	Objc._init();

	Module._init();
	Module.amodules = Module.amodules.init;
	Module.deferred = Dsymbols();    // deferred Dsymbol's needing semantic() run on them
	Module.deferred2 = Dsymbols();   // deferred Dsymbol's needing semantic2() run on them
	Module.deferred3 = Dsymbols();   // deferred Dsymbol's needing semantic3() run on them
	Module.dprogress = 0;      // progress resolving the deferred list

	dinterpret_init();

	clearSemanticStatics();
}

////////////////////////////////////////////////////////////////

extern(C) int _CrtDumpMemoryLeaks();
extern(C) void dumpGC();

////////////////////////////////////////////////////////////////
unittest
{
	//_CrtDumpMemoryLeaks();
	version(traceGC)
		dumpGC();

	DMDServer srv = newCom!DMDServer;
	srv.mPredefineVersions = true;
	addref(srv);
	scope(exit) release(srv);

	auto filename = allocBSTR("source.d");
	auto imp = allocBSTR(r"c:\s\d\rainers\druntime\import" ~ "\n" ~
						 r"c:\s\d\rainers\phobos");
	auto empty = allocBSTR("");
	uint flags = ConfigureFlags!()(false, //bool unittestOn
								   false, //bool debugOn,
								   true,  //bool x64
								   false, //bool cov
								   false, //bool doc,
								   false, //bool nobounds,
								   false, //bool gdc,
								   0,     //int versionLevel,
								   0,     //int debugLevel,
								   false, //bool noDeprecated,
								   false, //bool ldc,
								   true,  //bool msvcrt,
								   true,  //bool mixinAnalysis,
								   true); //bool ufcsExpansionsfalse,

	HRESULT hr;
	hr = srv.ConfigureSemanticProject(filename, imp, empty, empty, empty, flags);
	assert(hr == S_OK);

	void checkErrors(string src, string expected_err)
	{
		auto source = allocBSTR(src);
		HRESULT hr = srv.UpdateModule(filename, source, false);
		assert(hr == S_OK);
		BSTR errors;
		while (srv.GetParseErrors(filename, &errors) == S_FALSE)
			Thread.sleep(10.msecs);

		string err = detachBSTR(errors);
		assert(err == expected_err);
		freeBSTR(source);
	}

	void checkTip(int line, int col, string expected_tip)
	{
		HRESULT hr = srv.GetTip(filename, line, col, line, col + 1, 0);
		assert(hr == S_OK);
		BSTR bstrTip;
		int startLine, startIndex, endLine, endIndex;
		while (srv.GetTipResult(startLine, startIndex, endLine, endIndex, &bstrTip) == S_FALSE || _stricmp(bstrTip, "__pending__"w) == 0)
		{
			detachBSTR(bstrTip);
			Thread.sleep(10.msecs);
		}

		string tip = detachBSTR(bstrTip);
		assert(tip == expected_tip);
	}

	void checkDefinition(int line, int col, string expected_fname, int expected_line, int expected_col)
	{
		HRESULT hr = srv.GetDefinition(filename, line, col, line, col + 1);
		assert(hr == S_OK);
		BSTR bstrFile;
		int startLine, startIndex, endLine, endIndex;
		while (srv.GetDefinitionResult(startLine, startIndex, endLine, endIndex, &bstrFile) == S_FALSE || _stricmp(bstrFile, "__pending__"w) == 0)
		{
			detachBSTR(bstrFile);
			Thread.sleep(10.msecs);
		}

		string file = detachBSTR(bstrFile);
		assert(file == expected_fname);
		assert(startLine == expected_line);
		assert(startIndex == expected_col);
	}

	string source;
/+
	source = q{
		int main()
		{
			return abc;
		}
	};
	checkErrors(source, "4,10,4,11:undefined identifier `abc`\n");

	GC.collect();

	source = q{
		int main()
		{
			return abcd;
		}
	};
	checkErrors(source, "4,10,4,11:undefined identifier `abcd`\n");
+/
	version(traceGC)
		wipeStack();
	GC.collect();

	//_CrtDumpMemoryLeaks();
	version(traceGC)
		dumpGC();

	for (int i = 0; i < 2; i++)
	{
		srv.mModules = null;
		//clearDmdStatics ();

		source = q{
			import std.stdio;
			int main(string[] args)
			{
				int xyz = 7;
				writeln(1, 2, 3);
				return xyz;
			}
		};
		checkErrors(source, "");

		version(traceGC)
			wipeStack();
		GC.collect();

		//_CrtDumpMemoryLeaks();
		version(traceGC)
			dumpGC();
	}

	checkTip(5, 9, "(local variable) int xyz");
	checkTip(6, 9, "void std.stdio.writeln!(int, int, int).writeln(int _param_0, int _param_1, int _param_2) @safe");
	checkTip(7, 12, "(local variable) int xyz");

	version(traceGC)
		wipeStack();
	GC.collect();

	checkDefinition(7, 12, "source.d", 5, 9); // xyz
}

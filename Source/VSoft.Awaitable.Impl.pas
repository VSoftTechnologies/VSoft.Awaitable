{***************************************************************************}
{                                                                           }
{           VSoft.Awaitable - Async/Await for Delphi                        }
{                                                                           }
{           Copyright � 2020 Vincent Parrett and contributors               }
{                                                                           }
{           vincent@finalbuilder.com                                        }
{           https://www.finalbuilder.com                                    }
{                                                                           }
{                                                                           }
{***************************************************************************}
{                                                                           }
{  Licensed under the Apache License, Version 2.0 (the "License");          }
{  you may not use this file except in compliance with the License.         }
{  You may obtain a copy of the License at                                  }
{                                                                           }
{      http://www.apache.org/licenses/LICENSE-2.0                           }
{                                                                           }
{  Unless required by applicable law or agreed to in writing, software      }
{  distributed under the License is distributed on an "AS IS" BASIS,        }
{  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. }
{  See the License for the specific language governing permissions and      }
{  limitations under the License.                                           }
{                                                                           }
{***************************************************************************}

//NOTE : Do not use this unit directly,  use TAsync in VSoft.Awaitable.

//  Design note - message pump requirement
//  ---------------------------------------
//  Completions (Await / OnException / OnCancellation) are marshalled back to the
//  thread that called Await, by posting a message to a hidden window owned by that
//  thread. That thread MUST pump its message queue for the callbacks to run - this
//  matches how OmniThreadLibrary (the previous implementation) delivered
//  OnTerminated. In practice this library is driven from the main (VCL) thread,
//  which always pumps. Using it from a thread that never pumps messages is not
//  supported and will leak the pending completion.

unit VSoft.Awaitable.Impl;

interface

uses
  System.Classes,
  System.SysUtils,
  VSoft.CancellationToken,
  VSoft.Awaitable;

type
  //  Internal interface used by the worker thread to join/leave a group.
  IAwaitableGroupInternal = interface
    ['{7C6E5D1B-2F4A-4C3E-9B8D-1A2B3C4D5E6F}']
    procedure Join(const thread : TThread; const token : ICancellationToken);
    procedure Leave(const thread : TThread);
  end;

  TAwaitable = class(TInterfacedObject, IAwaitable)
  protected
  type
      TCallType = (ctProc, ctCancellableProc, ctFunc, ctCancellableFunc);

  protected
    FCallType : TCallType;

    //async
    FAsyncProc : TProc;
    FCancellableAsyncProc : TAsyncCancellableProc;

    //OnCancel
    FCancelProc : TProc;
    //OnException
    FExceptionProc : TExceptionProc;

    FGroup : IAwaitableGroup;

    FCancellationToken : ICancellationToken;

    procedure Await(const proc: TProc);
    function OnException(const proc : TExceptionProc) : IAwaitable; overload;
    function OnCancellation(const proc : TProc) : IAwaitable; overload;
    function GroupedBy(const aGroup : IAwaitableGroup) : IAwaitable; overload;


  public
    constructor Create(const asyncProc: TAsyncCancellableProc; const cancellationToken : ICancellationToken);overload;
    constructor Create(const asyncProc: TAsyncProc);overload;

  end;


  TAwaitable<TResult> = class(TAwaitable, IAwaitable<TResult>)
  private
    //async
    FAsyncFunc : TAsyncFunc<TResult>;
    FCancellableAsyncFunc : TAsyncCancellableFunc<TResult>;
  protected
    procedure Await(const proc: TResultProc<TResult>);
    function OnException(const proc : TExceptionProc) : IAwaitable<TResult>; overload;
    function OnCancellation(const proc : TProc) : IAwaitable<TResult>; overload;
    function GroupedBy(const aGroup : IAwaitableGroup) : IAwaitable<TResult>; overload;
  public
    constructor Create(const asyncFunc: TAsyncCancellableFunc<TResult>;const cancellationToken : ICancellationToken );overload;
    constructor Create(const asyncFunc: TAsyncFunc<TResult>);overload;

  end;

  TAwaitableGroupFactory = class
  public
    class function New: IAwaitableGroup;
  end;

  //  Starts worker on a background thread and arranges for completion to run on
  //  the calling thread. Declared here (not as an implementation-local symbol) so
  //  that the generic TAwaitable<TResult>.Await can call it.
  procedure RunAsync(const worker : TProc; const completion : TExceptionProc;
                     const group : IAwaitableGroupInternal; const token : ICancellationToken);

  //  Diagnostics for tests - the number of live per-thread dispatchers (one hidden
  //  window each). Used to verify that tasks started from the same thread share a
  //  single dispatcher, and that dispatchers free themselves once idle.
  function AwaitableLiveDispatcherCount : integer;

implementation

uses
  Winapi.Windows,
  Winapi.Messages,
  System.SyncObjs,
  System.Generics.Collections;

const
  WM_ASYNC_COMPLETE = WM_APP + 1;
  //  bounded retry when the target thread's message queue is momentarily full.
  CMaxPostRetries   = 100;

type
  //  One queued completion - the callback to run on the calling thread plus the
  //  captured exception (may be nil). Ownership of Exc passes to Completion, which
  //  either hands it to OnException (and frees it) or re-raises it.
  TCompletionItem = record
    Completion : TExceptionProc;
    Exc        : Exception;
  end;

  //  Owns a single hidden message window PER CALLING THREAD (mirroring
  //  OmniThreadLibrary's TOmniEventMonitorPool, which keeps one monitor window per
  //  thread rather than one per task). Worker threads push their completion onto a
  //  thread-safe queue and post a lightweight wake-up; the WndProc (running on the
  //  owning thread) drains the queue. The dispatcher is reference counted by the
  //  number of in-flight tasks and frees itself - on its owning thread - once idle.
  TAsyncDispatcher = class
  private
    FWnd      : HWND;
    FThreadId : cardinal;
    FRefCount : integer;        // in-flight tasks; only mutated on the owning thread
    FLock     : TCriticalSection;
    FQueue    : TQueue<TCompletionItem>;
    procedure WndProc(var msg : TMessage);
    procedure DrainQueue;
    procedure MaybeFreeIfIdle;
  public
    constructor Create(const threadId : cardinal);
    destructor Destroy; override;
    //  Called on the worker thread - enqueues the completion and wakes the owner.
    procedure PostCompletion(const completion : TExceptionProc; const exc : Exception);
    property Wnd : HWND read FWnd;
  end;

  //  Runs the user proc/func on a worker thread, captures any exception, then hands
  //  it (and ownership) to the calling thread's dispatcher. The thread is
  //  FreeOnTerminate - the RTL disposes of it once Execute returns.
  TAsyncThread = class(TThread)
  private
    FWorker     : TProc;
    FCompletion : TExceptionProc;
    FDispatcher : TAsyncDispatcher;
    FGroup      : IAwaitableGroupInternal;
  protected
    procedure Execute; override;
  public
    constructor Create(const worker : TProc; const completion : TExceptionProc;
                       const dispatcher : TAsyncDispatcher; const group : IAwaitableGroupInternal);
  end;

  TGroupMember = record
    Thread : TThread;
    Token  : ICancellationToken;
  end;

  TAwaitableGroup = class(TInterfacedObject, IAwaitableGroup, IAwaitableGroupInternal)
  private
    FLock     : TCriticalSection;
    FAllDone  : TEvent;
    FMembers  : TList<TGroupMember>;
    function IndexOfThread(const thread : TThread) : integer;
  protected
    // IAwaitableGroup
    function CancelAll: Boolean;
    function WaitForAll(maxWait_ms: cardinal = INFINITE): Boolean;
    function Any: Boolean;
    function IsEmpty: Boolean;
    // IAwaitableGroupInternal
    procedure Join(const thread : TThread; const token : ICancellationToken);
    procedure Leave(const thread : TThread);
  public
    constructor Create;
    destructor Destroy; override;
  end;

var
  //  AllocateHWnd/DeallocateHWnd share a single utility window class that is
  //  not reliably thread safe on older compilers - guard access. Also guards the
  //  per-thread dispatcher registry below.
  GWndLock     : TCriticalSection;
  //  One dispatcher per calling thread, keyed by thread id.
  GDispatchers : TDictionary<cardinal, TAsyncDispatcher>;
  //  Live dispatcher count, for test diagnostics only.
  GLiveDispatchers : integer;


function AwaitableLiveDispatcherCount : integer;
begin
  result := GLiveDispatchers;
end;


{ dispatcher pool }

//  Returns the dispatcher for the current thread, creating it on first use, and
//  takes a reference for the task about to be scheduled. Runs on the calling thread.
function AcquireDispatcher : TAsyncDispatcher;
var
  tid  : cardinal;
  disp : TAsyncDispatcher;
begin
  tid := GetCurrentThreadId;
  GWndLock.Enter;
  try
    if not GDispatchers.TryGetValue(tid, disp) then
    begin
      //  AllocateHWnd (inside Create) runs under GWndLock which we already hold.
      disp := TAsyncDispatcher.Create(tid);
      GDispatchers.Add(tid, disp);
    end;
    Inc(disp.FRefCount);
  finally
    GWndLock.Leave;
  end;
  result := disp;
end;

//  Releases a reference taken by AcquireDispatcher without a completion having run -
//  used only to roll back when scheduling fails. Runs on the owning thread.
procedure ReleaseDispatcher(const disp : TAsyncDispatcher);
begin
  Dec(disp.FRefCount);
  disp.MaybeFreeIfIdle;
end;


{ TAsyncDispatcher }

constructor TAsyncDispatcher.Create(const threadId: cardinal);
begin
  //  Created on the calling thread - the hidden window belongs to this thread.
  //  Caller (AcquireDispatcher) holds GWndLock, so AllocateHWnd is serialised.
  inherited Create;
  FThreadId := threadId;
  FLock := TCriticalSection.Create;
  FQueue := TQueue<TCompletionItem>.Create;
  FWnd := AllocateHWnd(WndProc);
  InterlockedIncrement(GLiveDispatchers);
end;

destructor TAsyncDispatcher.Destroy;
var
  item : TCompletionItem;
begin
  //  Free any completions that were queued but never delivered (e.g. shutdown).
  while FQueue.Count > 0 do
  begin
    item := FQueue.Dequeue;
    if item.Exc <> nil then
      item.Exc.Free;
  end;
  FQueue.Free;
  if FWnd <> 0 then
  begin
    GWndLock.Enter;
    try
      DeallocateHWnd(FWnd);
    finally
      GWndLock.Leave;
    end;
  end;
  FLock.Free;
  InterlockedDecrement(GLiveDispatchers);
  inherited;
end;

procedure TAsyncDispatcher.PostCompletion(const completion: TExceptionProc; const exc: Exception);
var
  item     : TCompletionItem;
  wnd      : HWND;
  attempts : integer;
begin
  item.Completion := completion;
  item.Exc := exc;

  //  Capture the window handle BEFORE releasing the lock. Once the item is queued
  //  and the lock released, another thread's wake-up may drain it and free this
  //  dispatcher, so we must not touch any field of Self afterwards - only 'wnd'.
  //  While we hold FLock a drain cannot dequeue our item, so Self stays alive here.
  wnd := FWnd;
  FLock.Enter;
  try
    FQueue.Enqueue(item);
  finally
    FLock.Leave;
  end;

  //  Wake the owning thread. Tolerate a momentarily full queue (OTL does the same);
  //  the payload is safely queued, so a lost wake-up is recovered by the next one
  //  or by TAwaitableGroup.WaitForAll pumping.
  attempts := 0;
  while not PostMessage(wnd, WM_ASYNC_COMPLETE, 0, 0) do
  begin
    if GetLastError <> ERROR_NOT_ENOUGH_QUOTA then
      Break;
    Inc(attempts);
    if attempts >= CMaxPostRetries then
      Break;
    Sleep(1);
  end;
end;

procedure TAsyncDispatcher.DrainQueue;
var
  item    : TCompletionItem;
  hasItem : boolean;
  lExc    : Exception;
begin
  //  Runs on the owning thread. Drain everything currently queued.
  repeat
    hasItem := false;
    FLock.Enter;
    try
      if FQueue.Count > 0 then
      begin
        item := FQueue.Dequeue;
        hasItem := true;
      end;
    finally
      FLock.Leave;
    end;

    if hasItem then
    begin
      //  Account for the completed task before running the callback, so a callback
      //  that raises still leaves the reference count correct.
      Dec(FRefCount);
      lExc := item.Exc;
      //  Ownership of lExc belongs to the completion callback, which either hands it
      //  to OnException (and frees it) or re-raises it.
      if Assigned(item.Completion) then
        item.Completion(lExc)
      else if lExc <> nil then
        lExc.Free;
    end;
  until not hasItem;
end;

procedure TAsyncDispatcher.MaybeFreeIfIdle;
var
  needFree : boolean;
begin
  //  Runs on the owning thread. Free (and drop from the pool) once no tasks are in
  //  flight and nothing is queued. A completion that scheduled more work (reentrant
  //  Await) will have re-incremented FRefCount, keeping us alive.
  GWndLock.Enter;
  try
    FLock.Enter;
    try
      needFree := (FRefCount <= 0) and (FQueue.Count = 0);
    finally
      FLock.Leave;
    end;
    if needFree then
      GDispatchers.Remove(FThreadId);
  finally
    GWndLock.Leave;
  end;
  if needFree then
    Self.Free;
end;

procedure TAsyncDispatcher.WndProc(var msg: TMessage);
begin
  if msg.Msg = WM_ASYNC_COMPLETE then
  begin
    try
      DrainQueue;
    finally
      //  Even if a completion re-raised, decide whether to self-destruct. When a
      //  completion raised, the queue is not empty (remaining items) so we won't
      //  free - the pending wake-ups will drive another drain.
      MaybeFreeIfIdle;
    end;
  end
  else
    msg.Result := DefWindowProc(FWnd, msg.Msg, msg.WParam, msg.LParam);
end;


{ TAsyncThread }

constructor TAsyncThread.Create(const worker: TProc; const completion: TExceptionProc;
  const dispatcher: TAsyncDispatcher; const group: IAwaitableGroupInternal);
begin
  inherited Create(true);
  FreeOnTerminate := true;
  FWorker := worker;
  FCompletion := completion;
  FDispatcher := dispatcher;
  FGroup := group;
end;

procedure TAsyncThread.Execute;
var
  lExc : Exception;
begin
  lExc := nil;
  try
    FWorker;
  except
    //  hard cast - we know a raised exception object is an Exception.
    lExc := Exception(AcquireExceptionObject);
  end;

  //  Leave the group from the worker thread so a caller blocking the calling
  //  thread in WaitForAll still sees the task drain (the completion callback
  //  runs later, once that thread pumps messages).
  if FGroup <> nil then
    FGroup.Leave(Self);

  //  Marshal completion (and ownership of lExc) back to the calling thread. After
  //  this call the dispatcher may be freed by a concurrent drain - do not touch it.
  FDispatcher.PostCompletion(FCompletion, lExc);
end;


procedure RunAsync(const worker : TProc; const completion : TExceptionProc;
                   const group : IAwaitableGroupInternal; const token : ICancellationToken);
var
  dispatcher : TAsyncDispatcher;
  thread     : TAsyncThread;
begin
  dispatcher := AcquireDispatcher;
  thread := nil;
  try
    thread := TAsyncThread.Create(worker, completion, dispatcher, group);
    if group <> nil then
      group.Join(thread, token);
    thread.Start;
  except
    //  Scheduling failed (e.g. OOM). Undo the group membership / thread and release
    //  the dispatcher reference so it does not linger.
    if thread <> nil then
    begin
      if group <> nil then
        group.Leave(thread);
      thread.FreeOnTerminate := False;
      thread.Free;
    end;
    ReleaseDispatcher(dispatcher);
    raise;
  end;
end;


{ TAwaitable<TResult> }

procedure TAwaitable<TResult>.Await(const proc: TResultProc<TResult>);
var
  theResult : TResult;

  lAsyncFunc : TAsyncFunc<TResult>;
  lcAsyncFunc : TAsyncCancellableFunc<TResult>;

  lOnException : TExceptionProc;
  lCancelledProc : TProc;
  lCallType : TCallType;

  cancelToken : ICancellationToken;
  lGroup : IAwaitableGroupInternal;

  worker : TProc;
  completion : TExceptionProc;
begin
  //local references for closures.
  lAsyncFunc :=  FAsyncFunc;
  lcAsyncFunc := FCancellableAsyncFunc;

  lOnException := FExceptionProc;
  lCancelledProc := FCancelProc;

  if FGroup <> nil then
    Supports(FGroup, IAwaitableGroupInternal, lGroup)
  else
    lGroup := nil;

  cancelToken := FCancellationToken;

  theResult := Default(TResult);

  lCallType := FCallType;

  worker := procedure
    begin
      case lCallType of
        ctFunc              : theResult := lAsyncFunc;
        ctCancellableFunc   : theResult := lcAsyncFunc(cancelToken);
      else
        raise Exception.Create('Whoa something is messed up.');
      end;
    end;

  completion := procedure(const exc : Exception)
    begin
      if exc <> nil then
      begin
        if Assigned(lOnException) then
        begin
          //  we own exc here - free it once the handler has run.
          try
            lOnException(exc);
          finally
            exc.Free;
          end;
        end
        else
          raise exc; //ownership transfers to the exception handling machinery.
      end
      else
      begin
        //  Cancellation is judged here, at delivery time: a worker that cooperatively
        //  exits its loop on IsCancelled returns normally, and we deliver OnCancellation
        //  rather than the (unused) result. This is intentional - see the unit notes.
        if Assigned(cancelToken) and cancelToken.IsCancelled then
        begin
          if Assigned(lCancelledProc) then
            lCancelledProc;
          exit;
        end;
        proc(theResult);
      end;
    end;

  RunAsync(worker, completion, lGroup, cancelToken);
end;

constructor TAwaitable<TResult>.Create(const asyncFunc: TAsyncCancellableFunc<TResult>;const cancellationToken : ICancellationToken );
begin
  inherited Create;
  if cancellationToken = nil then
    raise Exception.Create('A cancellation token is required for a cancellable async function.');
  FCallType := TCallType.ctCancellableFunc;
  FCancellableAsyncFunc := asyncFunc;
  FCancellationToken := cancellationToken;
end;

constructor TAwaitable<TResult>.Create(const asyncFunc: TAsyncFunc<TResult>);
begin
  inherited Create;
  FCallType := TCallType.ctFunc;
  FCancellableAsyncFunc := nil;
  FAsyncFunc := asyncFunc;
  FCancellationToken := nil;
end;

function TAwaitable<TResult>.GroupedBy(const aGroup: IAwaitableGroup): IAwaitable<TResult>;
begin
  FGroup := aGroup;
  result := Self;
end;

function TAwaitable<TResult>.OnCancellation(const proc: TProc): IAwaitable<TResult>;
begin
  if not Assigned(FCancellationToken) then
    raise Exception.Create('OnCancellation is only available if cancellation token passed in to TAsync.Configure');

  FCancelProc := proc;
  result := Self;
end;

function TAwaitable<TResult>.OnException(const proc: TExceptionProc): IAwaitable<TResult>;
begin
  FExceptionProc := proc;
  result := Self;
end;



{ TAwaitable }

procedure TAwaitable.Await(const proc: TProc);
var
  lProc  : TAsyncProc;
  lcProc : TAsyncCancellableProc;

  lOnException : TExceptionProc;
  lCancelledProc : TProc;
  lGroup : IAwaitableGroupInternal;

  lCallType : TCallType;

  cancelToken : ICancellationToken;

  worker : TProc;
  completion : TExceptionProc;
begin

  //local references for closures.
  lProc :=  FAsyncProc;
  lcProc := FCancellableAsyncProc;

  lOnException := FExceptionProc;
  lCancelledProc := FCancelProc;

  if FGroup <> nil then
    Supports(FGroup, IAwaitableGroupInternal, lGroup)
  else
    lGroup := nil;

  cancelToken := FCancellationToken;

  lCallType := FCallType;

  worker := procedure
    begin
      case lCallType of
        ctProc              : lProc;
        ctCancellableProc   : lcProc(cancelToken);
      else
        raise Exception.Create('Whoa something is messed up.');
      end;
    end;

  completion := procedure(const exc : Exception)
    begin
      if exc <> nil then
      begin
        if Assigned(lOnException) then
        begin
          //  we own exc here - free it once the handler has run.
          try
            lOnException(exc);
          finally
            exc.Free;
          end;
        end
        else
          raise exc; //ownership transfers to the exception handling machinery.
      end
      else
      begin
        //  Cancellation judged at delivery time - intentional, see the unit notes.
        if Assigned(cancelToken) and cancelToken.IsCancelled then
        begin
          if Assigned(lCancelledProc) then
            lCancelledProc;
          exit;
        end;
        proc;
      end;
    end;

  RunAsync(worker, completion, lGroup, cancelToken);
end;

constructor TAwaitable.Create(const asyncProc: TAsyncCancellableProc; const cancellationToken: ICancellationToken);
begin
  if cancellationToken = nil then
    raise Exception.Create('A cancellation token is required for a cancellable async procedure.');
  FCallType := TCallType.ctCancellableProc;
  FCancellableAsyncProc := asyncProc;
  FCancellationToken := cancellationToken;
end;

constructor TAwaitable.Create(const asyncProc: TAsyncProc);
begin
  FCallType := TCallType.ctProc;
  FAsyncProc := asyncProc;
  FCancellationToken := nil;
end;

function TAwaitable.GroupedBy(const aGroup: IAwaitableGroup): IAwaitable;
begin
  FGroup := aGroup;
  result := Self;
end;

function TAwaitable.OnCancellation(const proc: TProc): IAwaitable;
begin
  if not Assigned(FCancellationToken) then
    raise Exception.Create('OnCancellation is only available if a cancellation token passed in to TAsync.Configure');

  FCancelProc := proc;
  result := Self;

end;

function TAwaitable.OnException(const proc: TExceptionProc): IAwaitable;
begin
  FExceptionProc := proc;
  result := Self;
end;

{ TAwaitableGroup }

constructor TAwaitableGroup.Create;
begin
  inherited;
  FLock := TCriticalSection.Create;
  //  manual reset, starts signalled (empty group == all done).
  FAllDone := TEvent.Create(nil, true, true, '');
  FMembers := TList<TGroupMember>.Create;
end;

destructor TAwaitableGroup.Destroy;
begin
  FMembers.Free;
  FAllDone.Free;
  FLock.Free;
  inherited;
end;

function TAwaitableGroup.IndexOfThread(const thread: TThread): integer;
var
  i : integer;
begin
  for i := 0 to FMembers.Count - 1 do
    if FMembers[i].Thread = thread then
      Exit(i);
  result := -1;
end;

procedure TAwaitableGroup.Join(const thread: TThread; const token: ICancellationToken);
var
  member : TGroupMember;
begin
  FLock.Enter;
  try
    member.Thread := thread;
    member.Token := token;
    FMembers.Add(member);
    FAllDone.ResetEvent;
  finally
    FLock.Leave;
  end;
end;

procedure TAwaitableGroup.Leave(const thread: TThread);
var
  idx : integer;
begin
  FLock.Enter;
  try
    idx := IndexOfThread(thread);
    if idx >= 0 then
      FMembers.Delete(idx);
    if FMembers.Count = 0 then
      FAllDone.SetEvent;
  finally
    FLock.Leave;
  end;
end;

function TAwaitableGroup.Any: Boolean;
begin
  FLock.Enter;
  try
    result := FMembers.Count > 0;
  finally
    FLock.Leave;
  end;
end;

function TAwaitableGroup.IsEmpty: Boolean;
begin
  FLock.Enter;
  try
    result := FMembers.Count = 0;
  finally
    FLock.Leave;
  end;
end;

function TAwaitableGroup.CancelAll: Boolean;
var
  i : integer;
  manage : ICancellationTokenManage;
begin
  FLock.Enter;
  try
    for i := 0 to FMembers.Count - 1 do
      if FMembers[i].Token = nil then
        Exit(False);

    for i := 0 to FMembers.Count - 1 do
      if Supports(FMembers[i].Token, ICancellationTokenManage, manage) then
        manage.Cancel;
    result := True;
  finally
    FLock.Leave;
  end;
end;

function TAwaitableGroup.WaitForAll(maxWait_ms: cardinal): Boolean;
var
  msg       : TMsg;
  startTick : cardinal;
  elapsed   : cardinal;
begin
  //  Pump this thread's completion messages while waiting, so grouped Await /
  //  OnCancellation callbacks still drain even though the caller is blocking here
  //  (mirrors OmniThreadLibrary's ProcessMessages). Only our own WM_ASYNC_COMPLETE
  //  messages are dispatched - other messages are left in the queue.
  startTick := GetTickCount;
  result := false;
  repeat
    while PeekMessage(msg, 0, WM_ASYNC_COMPLETE, WM_ASYNC_COMPLETE, PM_REMOVE) do
      DispatchMessage(msg);

    if FAllDone.WaitFor(10) = TWaitResult.wrSignaled then
    begin
      //  Final drain for completions posted just before the last worker left.
      while PeekMessage(msg, 0, WM_ASYNC_COMPLETE, WM_ASYNC_COMPLETE, PM_REMOVE) do
        DispatchMessage(msg);
      result := true;
      Exit;
    end;

    if maxWait_ms <> INFINITE then
    begin
      elapsed := GetTickCount - startTick;
      if elapsed >= maxWait_ms then
        Exit; // result stays false
    end;
  until false;
end;

{ TAwaitableGroupFactory }

class function TAwaitableGroupFactory.New: IAwaitableGroup;
begin
  Result := TAwaitableGroup.Create;
end;

//  Free any dispatchers still registered at shutdown (best effort). In normal use
//  each dispatcher self-destructs once idle, so this is empty unless tasks are still
//  in flight when the app closes.
procedure FreeRemainingDispatchers;
var
  pair : TPair<cardinal, TAsyncDispatcher>;
  list : TList<TAsyncDispatcher>;
  i    : integer;
begin
  list := TList<TAsyncDispatcher>.Create;
  try
    GWndLock.Enter;
    try
      for pair in GDispatchers do
        list.Add(pair.Value);
      GDispatchers.Clear;
    finally
      GWndLock.Leave;
    end;
    for i := 0 to list.Count - 1 do
      list[i].Free;
  finally
    list.Free;
  end;
end;

initialization
  GWndLock := TCriticalSection.Create;
  GDispatchers := TDictionary<cardinal, TAsyncDispatcher>.Create;

finalization
  FreeRemainingDispatchers;
  GDispatchers.Free;
  GWndLock.Free;

end.

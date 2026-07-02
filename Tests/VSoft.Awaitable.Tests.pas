unit VSoft.Awaitable.Tests;

interface

uses
  DUnitX.TestFramework,
  VSoft.Awaitable;

type
  [TestFixture]
  TAwaitableTests = class
  public
    [Test]
    procedure Func_Returns_Result_To_Await;

    [Test]
    procedure Proc_Runs_And_Calls_Await;

    [Test]
    procedure Exception_Delivered_To_OnException_Not_Result;

    [Test]
    procedure Cancellation_Calls_OnCancellation_Not_Result;

    [Test]
    procedure Group_WaitForAll_Returns_True_When_Done;

    [Test]
    procedure Group_CancelAll_Signals_Tokens;

    [Test]
    procedure Group_CancelAll_Returns_False_When_Member_Has_No_Token;

    [Test]
    procedure Await_Runs_On_Calling_Thread;

    [Test]
    procedure OnException_Runs_On_Calling_Thread;

    [Test]
    procedure OnCancellation_Runs_On_Calling_Thread;

    //  When TAsync is used from a background thread (with its own message pump),
    //  the callbacks must run on THAT thread - not the main thread, not the
    //  async worker thread.
    [Test]
    procedure Await_Runs_On_Caller_Thread_Not_Main;

    [Test]
    procedure OnException_Runs_On_Caller_Thread_Not_Main;

    [Test]
    procedure OnCancellation_Runs_On_Caller_Thread_Not_Main;

    //  Tasks started from the same thread share one pooled dispatcher window, and
    //  the dispatcher frees itself once idle.
    [Test]
    procedure Tasks_From_Same_Thread_Share_One_Dispatcher;

    //  WaitForAll pumps our completion messages, so grouped callbacks run even when
    //  the caller does not run its own message loop.
    [Test]
    procedure WaitForAll_Pumps_Completions_Without_External_Pump;

    //  A cancellable Configure overload given a nil token must raise a clear error
    //  rather than letting a nil token reach user code.
    [Test]
    procedure Cancellable_Configure_With_Nil_Token_Raises;

    //  A completion callback that itself starts another async task must keep the
    //  per-thread dispatcher alive (no premature free) and both tasks must complete.
    [Test]
    procedure Reentrant_Await_From_Completion_Works;

    //  A cancellable func that finishes without being cancelled delivers its result
    //  to Await (the token-assigned-but-not-cancelled path).
    [Test]
    procedure Cancellable_Func_Not_Cancelled_Delivers_Result;

    //  A cancelled task with no OnCancellation handler must not call the result proc
    //  (documented intentional behaviour) and must not crash.
    [Test]
    procedure Cancelled_Without_OnCancellation_Does_Not_Call_Result;

    //  Firing a batch, draining it (dispatcher self-frees), then firing another batch
    //  must recreate the dispatcher and work - exercises create-after-idle-free.
    [Test]
    procedure Sequential_Batches_Reuse_Pool;

    //  Many concurrent tasks all complete exactly once and the dispatcher returns to
    //  zero afterwards - a soak / leak check on the queue and reference counting.
    [Test]
    procedure Many_Concurrent_Tasks_All_Complete_And_Free;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  Winapi.Windows,
  VSoft.Awaitable.Impl;

type
  TCallerMode = (cmAwait, cmException, cmCancellation);

  //  Uses TAsync from a background thread that runs its own message pump, and
  //  records the thread each stage ran on so a test can assert the callback ran
  //  on this (calling) thread rather than the main thread or the worker thread.
  TCallerThread = class(TThread)
  public
    Mode             : TCallerMode;
    CallerThreadId   : cardinal;
    WorkerThreadId   : cardinal;
    CallbackThreadId : cardinal;
  protected
    procedure Execute; override;
  end;

//  Completions are posted to the calling thread's hidden window, so the test
//  thread must pump the message queue for them to run. Pump until isDone or a
//  timeout elapses.
procedure PumpUntil(const isDone : TFunc<boolean>; const timeoutMs : cardinal);
var
  msg   : TMsg;
  start : cardinal;
begin
  start := GetTickCount;
  while not isDone() do
  begin
    if (GetTickCount - start) > timeoutMs then
      break;
    if PeekMessage(msg, 0, 0, 0, PM_REMOVE) then
    begin
      TranslateMessage(msg);
      DispatchMessage(msg);
    end
    else
      Sleep(1);
  end;
end;

{ TCallerThread }

procedure TCallerThread.Execute;
var
  done        : boolean;
  cancelled   : boolean;
  msg         : TMsg;
  start       : cardinal;
  tokenSource : ICancellationTokenSource;
begin
  CallerThreadId := GetCurrentThreadId;
  done := false;
  cancelled := false;
  tokenSource := nil;

  case Mode of
    cmAwait:
      TAsync.Configure<Integer>(
        function : Integer
        begin
          WorkerThreadId := GetCurrentThreadId;
          Sleep(20);
          result := 7;
        end)
      .Await(
        procedure(const value : Integer)
        begin
          CallbackThreadId := GetCurrentThreadId;
          done := true;
        end);

    cmException:
      TAsync.Configure<Integer>(
        function : Integer
        begin
          WorkerThreadId := GetCurrentThreadId;
          Sleep(20);
          raise Exception.Create('boom');
        end)
      .OnException(
        procedure(const e : Exception)
        begin
          CallbackThreadId := GetCurrentThreadId;
          done := true;
        end)
      .Await(
        procedure(const value : Integer)
        begin
          done := true;
        end);

    cmCancellation:
      begin
        tokenSource := TCancellationTokenSourceFactory.Create;
        TAsync.Configure<Integer>(
          function(const token : ICancellationToken) : Integer
          begin
            WorkerThreadId := GetCurrentThreadId;
            result := 0;
            while not token.IsCancelled do
              Sleep(1);
          end, tokenSource.Token)
        .OnCancellation(
          procedure
          begin
            CallbackThreadId := GetCurrentThreadId;
            done := true;
          end)
        .Await(
          procedure(const value : Integer)
          begin
            done := true;
          end);
      end;
  end;

  //  Run our own message pump on this background thread so the posted completion
  //  is dispatched here (this is the calling thread).
  start := GetTickCount;
  while not done do
  begin
    if (GetTickCount - start) > 3000 then
      break;
    if (Mode = cmCancellation) and (not cancelled) and ((GetTickCount - start) > 50) then
    begin
      tokenSource.Cancel;
      cancelled := true;
    end;
    if PeekMessage(msg, 0, 0, 0, PM_REMOVE) then
    begin
      TranslateMessage(msg);
      DispatchMessage(msg);
    end
    else
      Sleep(1);
  end;
end;

//  Asserts the callback ran on the caller (background) thread - not the main
//  thread and not the async worker thread.
procedure CheckRanOnCallerThread(const thread : TCallerThread);
begin
  Assert.AreNotEqual<cardinal>(cardinal(0), thread.CallerThreadId, 'caller thread did not run');
  Assert.AreNotEqual<cardinal>(cardinal(0), thread.CallbackThreadId, 'callback was not invoked');
  Assert.AreNotEqual<cardinal>(MainThreadID, thread.CallerThreadId, 'caller should be a background thread, not the main thread');
  Assert.AreEqual<cardinal>(thread.CallerThreadId, thread.CallbackThreadId, 'callback did not run on the calling (background) thread');
  Assert.AreNotEqual<cardinal>(MainThreadID, thread.CallbackThreadId, 'callback ran on the main thread instead of the caller thread');
  Assert.AreNotEqual<cardinal>(thread.WorkerThreadId, thread.CallbackThreadId, 'callback ran on the async worker thread');
end;

procedure RunCaller(const mode : TCallerMode);
var
  thread : TCallerThread;
begin
  thread := TCallerThread.Create(true);
  try
    thread.Mode := mode;
    thread.Start;
    thread.WaitFor;
    CheckRanOnCallerThread(thread);
  finally
    thread.Free;
  end;
end;

{ TAwaitableTests }

procedure TAwaitableTests.Func_Returns_Result_To_Await;
var
  done      : boolean;
  theResult : string;
begin
  done := false;
  theResult := '';
  TAsync.Configure<string>(
    function : string
    begin
      Sleep(20);
      result := 'Hello world';
    end)
  .Await(
    procedure(const value : string)
    begin
      theResult := value;
      done := true;
    end);

  PumpUntil(function : boolean begin result := done; end, 3000);

  Assert.IsTrue(done, 'Await callback was not invoked');
  Assert.AreEqual('Hello world', theResult);
end;

procedure TAwaitableTests.Proc_Runs_And_Calls_Await;
var
  done    : boolean;
  ran     : boolean;
begin
  done := false;
  ran := false;
  TAsync.Configure(
    procedure
    begin
      Sleep(20);
      ran := true;
    end)
  .Await(
    procedure
    begin
      done := true;
    end);

  PumpUntil(function : boolean begin result := done; end, 3000);

  Assert.IsTrue(ran, 'async proc did not run');
  Assert.IsTrue(done, 'Await callback was not invoked');
end;

procedure TAwaitableTests.Exception_Delivered_To_OnException_Not_Result;
var
  finished     : boolean;
  resultCalled : boolean;
  message      : string;
begin
  finished := false;
  resultCalled := false;
  message := '';
  TAsync.Configure<string>(
    function : string
    begin
      Sleep(20);
      raise Exception.Create('boom');
    end)
  .OnException(
    procedure(const e : Exception)
    begin
      message := e.Message;
      finished := true;
    end)
  .Await(
    procedure(const value : string)
    begin
      resultCalled := true;
      finished := true;
    end);

  PumpUntil(function : boolean begin result := finished; end, 3000);

  Assert.IsTrue(finished, 'neither handler was invoked');
  Assert.IsFalse(resultCalled, 'result callback should not run when an exception occurs');
  Assert.AreEqual('boom', message);
end;

procedure TAwaitableTests.Cancellation_Calls_OnCancellation_Not_Result;
var
  tokenSource  : ICancellationTokenSource;
  finished     : boolean;
  resultCalled : boolean;
  cancelled    : boolean;
begin
  tokenSource := TCancellationTokenSourceFactory.Create;
  finished := false;
  resultCalled := false;
  cancelled := false;

  TAsync.Configure<string>(
    function(const token : ICancellationToken) : string
    begin
      result := '';
      while not token.IsCancelled do
        Sleep(1);
    end, tokenSource.Token)
  .OnCancellation(
    procedure
    begin
      cancelled := true;
      finished := true;
    end)
  .Await(
    procedure(const value : string)
    begin
      resultCalled := true;
      finished := true;
    end);

  //  give the worker a moment to start, then cancel.
  Sleep(50);
  tokenSource.Cancel;

  PumpUntil(function : boolean begin result := finished; end, 3000);

  Assert.IsTrue(cancelled, 'OnCancellation was not invoked');
  Assert.IsFalse(resultCalled, 'result callback should not run when cancelled');
end;

procedure TAwaitableTests.Group_WaitForAll_Returns_True_When_Done;
var
  group     : IAwaitableGroup;
  completed : integer;
  i         : integer;
  allDone   : boolean;
begin
  group := TAwaitableGroupFactory.New;
  completed := 0;

  for i := 0 to 2 do
  begin
    TAsync.Configure<Integer>(
      function : Integer
      begin
        Sleep(100);
        result := 1;
      end)
    .GroupedBy(group)
    .Await(
      procedure(const value : Integer)
      begin
        Inc(completed);
      end);
  end;

  Assert.IsTrue(group.Any, 'group should have members right after starting');

  allDone := group.WaitForAll(5000);
  Assert.IsTrue(allDone, 'WaitForAll timed out');
  Assert.IsTrue(group.IsEmpty, 'group should be empty once all tasks have finished');

  //  drain the posted completions so the worker objects free themselves.
  PumpUntil(function : boolean begin result := completed = 3; end, 3000);
  Assert.AreEqual(3, completed);
end;

procedure TAwaitableTests.Group_CancelAll_Signals_Tokens;
var
  group     : IAwaitableGroup;
  sources   : array[0..2] of ICancellationTokenSource;
  completed : integer;
  i         : integer;
  cancelledOk : boolean;
begin
  group := TAwaitableGroupFactory.New;
  completed := 0;

  for i := 0 to 2 do
  begin
    sources[i] := TCancellationTokenSourceFactory.Create;
    TAsync.Configure<Integer>(
      function(const token : ICancellationToken) : Integer
      begin
        result := 0;
        while not token.IsCancelled do
          Sleep(1);
      end, sources[i].Token)
    .GroupedBy(group)
    .OnCancellation(
      procedure
      begin
        Inc(completed);
      end)
    .Await(
      procedure(const value : Integer)
      begin
      end);
  end;

  Sleep(50);
  cancelledOk := group.CancelAll;
  Assert.IsTrue(cancelledOk, 'CancelAll should succeed when every member has a token');

  Assert.IsTrue(group.WaitForAll(5000), 'tasks did not stop after CancelAll');

  //  drain the posted cancellation callbacks so the dispatchers free themselves.
  PumpUntil(function : boolean begin result := completed = 3; end, 3000);
  Assert.AreEqual(3, completed, 'each cancelled task should invoke OnCancellation');

  //  keep the sources alive until here.
  for i := 0 to 2 do
    sources[i] := nil;
end;

procedure TAwaitableTests.Group_CancelAll_Returns_False_When_Member_Has_No_Token;
var
  group : IAwaitableGroup;
  tokenSource : ICancellationTokenSource;
  gate : ICancellationTokenSource;
  terminated : integer;
begin
  group := TAwaitableGroupFactory.New;
  gate := TCancellationTokenSourceFactory.Create;
  tokenSource := TCancellationTokenSourceFactory.Create;
  terminated := 0;

  //  one cancellable member (has a token)...
  TAsync.Configure(
    procedure(const token : ICancellationToken)
    begin
      while not token.IsCancelled do
        Sleep(1);
    end, tokenSource.Token)
  .GroupedBy(group)
  .OnCancellation(procedure begin Inc(terminated); end)
  .Await(procedure begin end);

  //  ...and one non-cancellable member (no token) - CancelAll must report False.
  TAsync.Configure(
    procedure
    begin
      while not gate.Token.IsCancelled do
        Sleep(1);
    end)
  .GroupedBy(group)
  .Await(procedure begin Inc(terminated); end);

  Sleep(50);
  Assert.IsFalse(group.CancelAll, 'CancelAll should fail when a member has no token');

  //  release both workers so they can finish.
  tokenSource.Cancel;
  gate.Cancel;
  Assert.IsTrue(group.WaitForAll(5000), 'tasks did not finish');

  //  drain the posted callbacks so the dispatchers free themselves.
  PumpUntil(function : boolean begin result := terminated = 2; end, 3000);
  Assert.AreEqual(2, terminated, 'both tasks should invoke a terminal callback');
end;

procedure TAwaitableTests.Await_Runs_On_Calling_Thread;
var
  done             : boolean;
  workerThreadId   : cardinal;
  callbackThreadId : cardinal;
begin
  done := false;
  workerThreadId := 0;
  callbackThreadId := 0;

  TAsync.Configure<Integer>(
    function : Integer
    begin
      workerThreadId := GetCurrentThreadId;
      Sleep(20);
      result := 42;
    end)
  .Await(
    procedure(const value : Integer)
    begin
      callbackThreadId := GetCurrentThreadId;
      done := true;
    end);

  PumpUntil(function : boolean begin result := done; end, 3000);

  Assert.IsTrue(done, 'Await callback was not invoked');
  Assert.AreNotEqual<cardinal>(0, workerThreadId, 'worker did not run');
  Assert.AreNotEqual<cardinal>(workerThreadId, callbackThreadId, 'Await callback ran on the worker thread, not the calling thread');
  Assert.AreEqual<cardinal>(MainThreadID, callbackThreadId, 'Await callback did not run on the calling (main) thread');
end;

procedure TAwaitableTests.OnException_Runs_On_Calling_Thread;
var
  done             : boolean;
  workerThreadId   : cardinal;
  callbackThreadId : cardinal;
begin
  done := false;
  workerThreadId := 0;
  callbackThreadId := 0;

  TAsync.Configure<Integer>(
    function : Integer
    begin
      workerThreadId := GetCurrentThreadId;
      Sleep(20);
      raise Exception.Create('boom');
    end)
  .OnException(
    procedure(const e : Exception)
    begin
      callbackThreadId := GetCurrentThreadId;
      done := true;
    end)
  .Await(
    procedure(const value : Integer)
    begin
      done := true;
    end);

  PumpUntil(function : boolean begin result := done; end, 3000);

  Assert.IsTrue(done, 'OnException was not invoked');
  Assert.AreNotEqual<cardinal>(0, workerThreadId, 'worker did not run');
  Assert.AreNotEqual<cardinal>(workerThreadId, callbackThreadId, 'OnException ran on the worker thread, not the calling thread');
  Assert.AreEqual<cardinal>(MainThreadID, callbackThreadId, 'OnException did not run on the calling (main) thread');
end;

procedure TAwaitableTests.OnCancellation_Runs_On_Calling_Thread;
var
  tokenSource      : ICancellationTokenSource;
  done             : boolean;
  workerThreadId   : cardinal;
  callbackThreadId : cardinal;
begin
  tokenSource := TCancellationTokenSourceFactory.Create;
  done := false;
  workerThreadId := 0;
  callbackThreadId := 0;

  TAsync.Configure<Integer>(
    function(const token : ICancellationToken) : Integer
    begin
      workerThreadId := GetCurrentThreadId;
      result := 0;
      while not token.IsCancelled do
        Sleep(1);
    end, tokenSource.Token)
  .OnCancellation(
    procedure
    begin
      callbackThreadId := GetCurrentThreadId;
      done := true;
    end)
  .Await(
    procedure(const value : Integer)
    begin
      done := true;
    end);

  Sleep(50);
  tokenSource.Cancel;

  PumpUntil(function : boolean begin result := done; end, 3000);

  Assert.IsTrue(done, 'OnCancellation was not invoked');
  Assert.AreNotEqual<cardinal>(0, workerThreadId, 'worker did not run');
  Assert.AreNotEqual<cardinal>(workerThreadId, callbackThreadId, 'OnCancellation ran on the worker thread, not the calling thread');
  Assert.AreEqual<cardinal>(MainThreadID, callbackThreadId, 'OnCancellation did not run on the calling (main) thread');
end;

procedure TAwaitableTests.Await_Runs_On_Caller_Thread_Not_Main;
begin
  RunCaller(cmAwait);
end;

procedure TAwaitableTests.OnException_Runs_On_Caller_Thread_Not_Main;
begin
  RunCaller(cmException);
end;

procedure TAwaitableTests.OnCancellation_Runs_On_Caller_Thread_Not_Main;
begin
  RunCaller(cmCancellation);
end;

procedure TAwaitableTests.Tasks_From_Same_Thread_Share_One_Dispatcher;
var
  i         : integer;
  completed : integer;
begin
  //  Drain any dispatcher left behind by an earlier test so we start from a clean
  //  baseline of zero live dispatchers.
  PumpUntil(function : boolean begin result := AwaitableLiveDispatcherCount = 0; end, 1000);
  Assert.AreEqual(0, AwaitableLiveDispatcherCount, 'expected no live dispatchers before starting');

  completed := 0;
  for i := 0 to 9 do
    TAsync.Configure<Integer>(
      function : Integer
      begin
        Sleep(20);
        result := 1;
      end)
    .Await(
      procedure(const value : Integer)
      begin
        Inc(completed);
      end);

  //  We are on the calling (main) thread and have NOT pumped messages yet, so all
  //  ten tasks must share a single per-thread dispatcher - not one window each.
  Assert.AreEqual(1, AwaitableLiveDispatcherCount, 'tasks on one thread should share a single dispatcher');

  //  Drain the completions; once idle the dispatcher frees itself.
  PumpUntil(function : boolean begin result := completed = 10; end, 5000);
  Assert.AreEqual(10, completed, 'not all completions were delivered');
  Assert.AreEqual(0, AwaitableLiveDispatcherCount, 'the dispatcher should free itself once idle');
end;

procedure TAwaitableTests.WaitForAll_Pumps_Completions_Without_External_Pump;
var
  group     : IAwaitableGroup;
  completed : integer;
begin
  group := TAwaitableGroupFactory.New;
  completed := 0;

  //  Three tasks with staggered durations - the first finishes long before the last.
  TAsync.Configure<Integer>(
    function : Integer begin Sleep(50);  result := 1; end)
    .GroupedBy(group)
    .Await(procedure(const value : Integer) begin Inc(completed); end);

  TAsync.Configure<Integer>(
    function : Integer begin Sleep(150); result := 1; end)
    .GroupedBy(group)
    .Await(procedure(const value : Integer) begin Inc(completed); end);

  TAsync.Configure<Integer>(
    function : Integer begin Sleep(300); result := 1; end)
    .GroupedBy(group)
    .Await(procedure(const value : Integer) begin Inc(completed); end);

  //  Block in WaitForAll WITHOUT running our own message loop. Because WaitForAll
  //  pumps our completion messages, the early task's callback must have run by the
  //  time it returns (the old implementation left completed at 0 here).
  Assert.IsTrue(group.WaitForAll(5000), 'WaitForAll timed out');
  Assert.IsTrue(completed >= 1, 'WaitForAll did not pump any completions');

  //  drain any stragglers.
  PumpUntil(function : boolean begin result := completed = 3; end, 3000);
  Assert.AreEqual(3, completed);
end;

procedure TAwaitableTests.Cancellable_Configure_With_Nil_Token_Raises;
begin
  //  cancellable procedure overload
  Assert.WillRaise(
    procedure
    begin
      TAsync.Configure(
        procedure(const token : ICancellationToken)
        begin
        end, nil);
    end, Exception, 'cancellable procedure with a nil token should raise');

  //  cancellable function overload
  Assert.WillRaise(
    procedure
    begin
      TAsync.Configure<Integer>(
        function(const token : ICancellationToken) : Integer
        begin
          result := 0;
        end, nil);
    end, Exception, 'cancellable function with a nil token should raise');
end;

procedure TAwaitableTests.Reentrant_Await_From_Completion_Works;
var
  outerDone : boolean;
  innerDone : boolean;
  innerValue : Integer;
begin
  outerDone := false;
  innerDone := false;
  innerValue := 0;

  TAsync.Configure<Integer>(
    function : Integer
    begin
      Sleep(20);
      result := 1;
    end)
  .Await(
    procedure(const value : Integer)
    begin
      outerDone := true;
      //  Start a second task from inside the completion of the first. This must
      //  reuse (and keep alive) the calling thread's dispatcher.
      TAsync.Configure<Integer>(
        function : Integer
        begin
          Sleep(20);
          result := 2;
        end)
      .Await(
        procedure(const innerVal : Integer)
        begin
          innerValue := innerVal;
          innerDone := true;
        end);
    end);

  PumpUntil(function : boolean begin result := outerDone and innerDone; end, 5000);

  Assert.IsTrue(outerDone, 'outer Await callback did not run');
  Assert.IsTrue(innerDone, 'reentrant Await callback did not run');
  Assert.AreEqual(2, innerValue, 'reentrant task returned the wrong result');
  Assert.AreEqual(0, AwaitableLiveDispatcherCount, 'dispatcher should free itself once both tasks are done');
end;

procedure TAwaitableTests.Cancellable_Func_Not_Cancelled_Delivers_Result;
var
  tokenSource  : ICancellationTokenSource;
  done         : boolean;
  cancelled    : boolean;
  theResult    : Integer;
begin
  tokenSource := TCancellationTokenSourceFactory.Create;
  done := false;
  cancelled := false;
  theResult := 0;

  TAsync.Configure<Integer>(
    function(const token : ICancellationToken) : Integer
    begin
      Sleep(20);
      //  finishes normally without ever observing cancellation.
      result := 99;
    end, tokenSource.Token)
  .OnCancellation(
    procedure
    begin
      cancelled := true;
      done := true;
    end)
  .Await(
    procedure(const value : Integer)
    begin
      theResult := value;
      done := true;
    end);

  PumpUntil(function : boolean begin result := done; end, 3000);

  Assert.IsFalse(cancelled, 'OnCancellation should not run when the token was never cancelled');
  Assert.AreEqual(99, theResult, 'a cancellable func that completes normally should deliver its result');
end;

procedure TAwaitableTests.Cancelled_Without_OnCancellation_Does_Not_Call_Result;
var
  tokenSource  : ICancellationTokenSource;
  resultCalled : boolean;
  workerLeft   : boolean;
begin
  tokenSource := TCancellationTokenSourceFactory.Create;
  resultCalled := false;
  workerLeft := false;

  //  No OnCancellation handler is configured. When the task is cancelled, the result
  //  proc must NOT be called (intentional 'silent swallow'), and nothing must crash.
  TAsync.Configure<Integer>(
    function(const token : ICancellationToken) : Integer
    begin
      result := 0;
      while not token.IsCancelled do
        Sleep(1);
      workerLeft := true;
    end, tokenSource.Token)
  .Await(
    procedure(const value : Integer)
    begin
      resultCalled := true;
    end);

  Sleep(50);
  tokenSource.Cancel;

  //  Pump for a while so any (erroneous) completion would have a chance to run.
  PumpUntil(function : boolean begin result := false; end, 500);

  Assert.IsTrue(workerLeft, 'worker did not observe cancellation');
  Assert.IsFalse(resultCalled, 'result proc must not run for a cancelled task with no OnCancellation');
end;

procedure TAwaitableTests.Sequential_Batches_Reuse_Pool;
var
  batch     : integer;
  i         : integer;
  completed : integer;
begin
  //  clean baseline
  PumpUntil(function : boolean begin result := AwaitableLiveDispatcherCount = 0; end, 1000);
  Assert.AreEqual(0, AwaitableLiveDispatcherCount, 'expected no live dispatchers before starting');

  for batch := 0 to 1 do
  begin
    completed := 0;
    for i := 0 to 4 do
      TAsync.Configure<Integer>(
        function : Integer
        begin
          Sleep(10);
          result := 1;
        end)
      .Await(
        procedure(const value : Integer)
        begin
          Inc(completed);
        end);

    Assert.AreEqual(1, AwaitableLiveDispatcherCount, 'each batch on one thread should use a single dispatcher');

    PumpUntil(function : boolean begin result := completed = 5; end, 5000);
    Assert.AreEqual(5, completed, 'batch did not complete');
    Assert.AreEqual(0, AwaitableLiveDispatcherCount, 'dispatcher should free itself between batches');
  end;
end;

procedure TAwaitableTests.Many_Concurrent_Tasks_All_Complete_And_Free;
const
  CTaskCount = 100;
var
  i         : integer;
  completed : integer;
begin
  //  clean baseline
  PumpUntil(function : boolean begin result := AwaitableLiveDispatcherCount = 0; end, 1000);
  Assert.AreEqual(0, AwaitableLiveDispatcherCount, 'expected no live dispatchers before starting');

  completed := 0;
  for i := 0 to CTaskCount - 1 do
    TAsync.Configure<Integer>(
      function : Integer
      begin
        Sleep(5);
        result := 1;
      end)
    .Await(
      procedure(const value : Integer)
      begin
        Inc(completed);
      end);

  PumpUntil(function : boolean begin result := completed = CTaskCount; end, 15000);

  Assert.AreEqual(CTaskCount, completed, 'not every task delivered its completion');
  Assert.AreEqual(0, AwaitableLiveDispatcherCount, 'the dispatcher should free itself once all tasks are done');
end;

initialization
  TDUnitX.RegisterTestFixture(TAwaitableTests);

end.

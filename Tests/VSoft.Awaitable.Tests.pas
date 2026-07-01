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
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  Winapi.Windows;

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

initialization
  TDUnitX.RegisterTestFixture(TAwaitableTests);

end.

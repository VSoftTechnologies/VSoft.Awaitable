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

implementation

uses
  Winapi.Windows,
  Winapi.Messages,
  System.SyncObjs,
  System.Generics.Collections;

const
  WM_ASYNC_COMPLETE = WM_APP + 1;

var
  //  AllocateHWnd/DeallocateHWnd share a single utility window class that is
  //  not reliably thread safe on older compilers - guard access.
  GWndLock : TCriticalSection;

type
  //  Owns a hidden message window on the CALLING thread and runs the completion
  //  callback there when the worker posts to it - mirroring OmniThreadLibrary's
  //  behaviour of invoking OnTerminated on the thread that created the task.
  //  Frees itself once the completion has run.
  TAsyncDispatcher = class
  private
    FWnd        : HWND;
    FCompletion : TExceptionProc;
    procedure WndProc(var msg : TMessage);
  public
    constructor Create(const completion : TExceptionProc);
    destructor Destroy; override;
    property Wnd : HWND read FWnd;
  end;

  //  Runs the user proc/func on a worker thread, captures any exception, then
  //  posts it (as the message WParam) to the dispatcher's window. The thread is
  //  FreeOnTerminate - the RTL disposes of it once Execute returns.
  TAsyncThread = class(TThread)
  private
    FWorker : TProc;
    FGroup  : IAwaitableGroupInternal;
    FWnd    : HWND;
  protected
    procedure Execute; override;
  public
    constructor Create(const worker : TProc; const wnd : HWND; const group : IAwaitableGroupInternal);
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


{ TAsyncDispatcher }

constructor TAsyncDispatcher.Create(const completion: TExceptionProc);
begin
  //  Created on the calling thread - the hidden window belongs to this thread.
  inherited Create;
  FCompletion := completion;
  GWndLock.Enter;
  try
    FWnd := AllocateHWnd(WndProc);
  finally
    GWndLock.Leave;
  end;
end;

destructor TAsyncDispatcher.Destroy;
begin
  if FWnd <> 0 then
  begin
    GWndLock.Enter;
    try
      DeallocateHWnd(FWnd);
    finally
      GWndLock.Leave;
    end;
  end;
  inherited;
end;

procedure TAsyncDispatcher.WndProc(var msg: TMessage);
var
  lExc : Exception;
begin
  if msg.Msg = WM_ASYNC_COMPLETE then
  begin
    //  Runs on the calling thread. Ownership of the captured exception (passed as
    //  the message WParam, may be nil) belongs to the completion callback, which
    //  either hands it to OnException (and frees it) or re-raises it.
    lExc := Exception(Pointer(msg.WParam));
    try
      if Assigned(FCompletion) then
        FCompletion(lExc)
      else
        lExc.Free;
    finally
      Free; // self destruct once the completion has run.
    end;
  end
  else
    msg.Result := DefWindowProc(FWnd, msg.Msg, msg.WParam, msg.LParam);
end;


{ TAsyncThread }

constructor TAsyncThread.Create(const worker: TProc; const wnd: HWND; const group: IAwaitableGroupInternal);
begin
  inherited Create(true);
  FreeOnTerminate := true;
  FWorker := worker;
  FWnd := wnd;
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

  //  Marshal completion (and ownership of lExc) back to the calling thread.
  PostMessage(FWnd, WM_ASYNC_COMPLETE, WPARAM(Pointer(lExc)), 0);
end;


procedure RunAsync(const worker : TProc; const completion : TExceptionProc;
                   const group : IAwaitableGroupInternal; const token : ICancellationToken);
var
  dispatcher : TAsyncDispatcher;
  thread : TAsyncThread;
begin
  dispatcher := TAsyncDispatcher.Create(completion);
  thread := TAsyncThread.Create(worker, dispatcher.Wnd, group);
  if group <> nil then
    group.Join(thread, token);
  thread.Start;
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
  FCallType := TCallType.ctCancellableFunc;
  FCancellableAsyncFunc := asyncFunc;
  FCancellationToken := cancellationToken;
  Assert(FCancellationToken <> nil);
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
begin
  result := FAllDone.WaitFor(maxWait_ms) = TWaitResult.wrSignaled;
end;

{ TAwaitableGroupFactory }

class function TAwaitableGroupFactory.New: IAwaitableGroup;
begin
  Result := TAwaitableGroup.Create;
end;

initialization
  GWndLock := TCriticalSection.Create;

finalization
  GWndLock.Free;

end.

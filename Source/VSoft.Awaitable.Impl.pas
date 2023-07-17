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

//NOTE : Do not use this unit directly, TAsync in VSoft.Awaitable.

unit VSoft.Awaitable.Impl;

interface

uses
  SysUtils,
  VSoft.Awaitable;

type
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

implementation

uses
  OtlTask,
  OtlTaskControl,
  OtlParallel,
  OtlSync;

type
  TAwaitableGroup = class(TInterfacedObject, IAwaitableGroup, IOmniTaskGroup)
  private
    FGroup: IOmniTaskGroup;
    property Group: IOmniTaskGroup read FGroup implements IOmniTaskGroup;
  public
    constructor Create;

    function CancelAll: Boolean;
    function WaitForAll(maxWait_ms: cardinal = INFINITE): Boolean;
    function Any: Boolean;
    function IsEmpty: Boolean;
  end;


{ TAwait<TResult> }

procedure TAwaitable<TResult>.Await(const proc: TResultProc<TResult>);
var
  omniTask  : IOmniTaskControl;
  task: TOmniTaskDelegate;
  taskConfig: IOmniTaskConfig;
  theResult : TResult;

  lAsyncFunc : TAsyncFunc<TResult>;
  lcAsyncFunc : TAsyncCancellableFunc<TResult>;


  lOnException : TExceptionProc;
  lCancelledProc : TProc;
  lCallType : TCallType;

  omniToken : IOmniCancellationToken;
  cancelToken : ICancellationToken;
  lGroup: IOmniTaskGroup;
begin
  //local references for closures.
  lAsyncFunc :=  FAsyncFunc;
  lcAsyncFunc := FCancellableAsyncFunc;

  lOnException := FExceptionProc;
  lCancelledProc := FCancelProc;
  lGroup := FGroup as IOmniTaskGroup;

  cancelToken := FCancellationToken;

  theResult := Default(TResult);

  taskConfig := Parallel.TaskConfig;

  omniToken := cancelToken  as IOmniCancellationToken;
  if Assigned(omniToken) then
    taskConfig.CancelWith(omniToken);

  lCallType := FCallType;

  task := procedure (const omniTask: IOmniTask)
    begin
      case lCallType of
        ctFunc              : theResult := lAsyncFunc;
        ctCancellableFunc   : theResult := lcAsyncFunc(cancelToken);
      else
        raise Exception.Create('Whoa something is messed up.');
      end;
    end;

  omniTask := CreateTask(task, 'VSoft.Async').Unobserved.OnTerminated(
    procedure (const task: IOmniTaskControl)
    var
      exc: Exception;
    begin
    //  terminated.Call(task);
      try
        exc := task.DetachException;
        if assigned(exc) then
        begin
          if Assigned(lOnException) then
            lOnException(exc)
          else
            raise exc;
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
      finally
        if lGroup <> nil then
          omniTask.Leave(lGroup);
      end;
    end);

  if lGroup <> nil then
    omniTask.Join(lGroup);

  Parallel.ApplyConfig(taskConfig, omniTask);
  omniTask.Unobserved;
  Parallel.Start(omniTask, taskConfig);
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
    raise Exception.Create('OnCancellation is only available if cancellation token passed in Async');

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
  omniTask  : IOmniTaskControl;
  task: TOmniTaskDelegate;
  taskConfig: IOmniTaskConfig;

  lProc  : TAsyncProc;
  lcProc : TAsyncCancellableProc;

  lOnException : TExceptionProc;
  lCancelledProc : TProc;
  lGroup : IOmniTaskGroup;

  lCallType : TCallType;

  omniToken : IOmniCancellationToken;
  cancelToken : ICancellationToken;
begin

  //local references for closures.
  lProc :=  FAsyncProc;
  lcProc := FCancellableAsyncProc;


  lOnException := FExceptionProc;
  lCancelledProc := FCancelProc;
  lGroup := (FGroup as IOmniTaskGroup);

  cancelToken := FCancellationToken;

  taskConfig := Parallel.TaskConfig;

  omniToken := cancelToken  as IOmniCancellationToken;
  if Assigned(omniToken) then
    taskConfig.CancelWith(omniToken);

  lCallType := FCallType;

  task := procedure (const omniTask: IOmniTask)
    begin
      case lCallType of
        ctProc              : lProc;
        ctCancellableProc   : lcProc(cancelToken);
      else
        raise Exception.Create('Whoa something is messed up.');
      end;
    end;


  omniTask := CreateTask(task, 'VSoft.Async').Unobserved.OnTerminated(
    procedure (const task: IOmniTaskControl)
    var
      exc: Exception;
    begin
      try
        exc := task.DetachException;
        if assigned(exc) then
        begin
          if Assigned(lOnException) then
            lOnException(exc)
          else
            raise exc;
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
      finally
        if lGroup <> nil then
          omniTask.Leave(lGroup);
      end;
    end);

  if lGroup <> nil then
    omniTask.Join(lGroup);

  Parallel.ApplyConfig(taskConfig, omniTask);
  omniTask.Unobserved;
  Parallel.Start(omniTask, taskConfig);

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
    raise Exception.Create('OnCancellation is only available if cancellation token passed in Async');

  FCancelProc := proc;
  result := Self;

end;

function TAwaitable.OnException(const proc: TExceptionProc): IAwaitable;
begin
  FExceptionProc := proc;
  result := Self;
end;

{ TAwaitableGroup }

function TAwaitableGroup.Any: Boolean;
begin
  Result := FGroup.Tasks.Count > 0;
end;

function TAwaitableGroup.CancelAll: Boolean;
var
  lTask: IOmniTaskControl;
begin
  Result := True;
  for lTask in FGroup do
  begin
    if lTask.CancellationToken = nil then
      Exit(False);
  end;

  for lTask in FGroup do
  begin
    if lTask.CancellationToken <> nil then
      lTask.CancellationToken.Signal
  end;
end;

constructor TAwaitableGroup.Create;
begin
  inherited;
  FGroup := TOmniTaskGroup.Create;
end;

function TAwaitableGroup.IsEmpty: Boolean;
begin
  Result := FGroup.Tasks.Count = 0;
end;

function TAwaitableGroup.WaitForAll(maxWait_ms: cardinal): Boolean;
begin
  Result := FGroup.WaitForAll(maxWait_ms);
end;

{ TAwaitableGroupFactory }

class function TAwaitableGroupFactory.New: IAwaitableGroup;
begin
  Result := TAwaitableGroup.Create;
end;

end.

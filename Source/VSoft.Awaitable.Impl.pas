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
  System.SysUtils,
  VSoft.Awaitable;

type
  TAwaitable<TResult> = class(TInterfacedObject, IAwaitable<TResult>)
  private
    FAsyncFunc : TAsyncFunc<TResult>;
    FCancellableAsyncFunc : TAsyncFunc<TResult, ICancellationToken>;
    FAwaitProc : TResultProc<TResult>;
    FCancelProc : TProc;
    FExceptionProc : TExceptionProc;

    FCancellationToken : ICancellationToken;
  protected
    function Await(const proc: TResultProc<TResult>) : IAwaitable<TResult>;overload;
    function OnException(const proc : TExceptionProc) : IAwaitable<TResult>;
    function OnCancellation(const proc : TProc) : IAwaitable<TResult>;
  public
    constructor Create(const asyncFunc: TAsyncFunc<TResult, ICancellationToken>;const cancellationToken : ICancellationToken );overload;
    constructor Create(const asyncFunc: TAsyncFunc<TResult>);overload;
  end;


implementation

uses
  OtlTask,
  OtlTaskControl,
  OtlParallel,
  OtlSync;


{ TAwait<TResult> }

function TAwaitable<TResult>.Await(const proc: TResultProc<TResult>): IAwaitable<TResult>;
var
  omniTask  : IOmniTaskControl;
//  terminated: TOmniTaskConfigTerminated;
  task: TOmniTaskDelegate;
  taskConfig: IOmniTaskConfig;
  theResult : TResult;
  lAsyncFunc : TAsyncFunc<TResult>;
  lcAsyncFunc : TAsyncFunc<TResult, ICancellationToken>;
  lOnException : TExceptionProc;
  lCancelledProc : TProc;
  omniToken : IOmniCancellationToken;
  cancelToken : ICancellationToken;
begin
  FAwaitProc := proc;
  lAsyncFunc :=  FAsyncFunc;
  lcAsyncFunc := FCancellableAsyncFunc;
  lOnException := FExceptionProc;
  lCancelledProc := FCancelProc;
  cancelToken := FCancellationToken;

  theResult := Default(TResult);

  taskConfig := Parallel.TaskConfig;

  omniToken := cancelToken  as IOmniCancellationToken;
  if Assigned(omniToken) then
    taskConfig.CancelWith(omniToken);

  task := procedure (const omniTask: IOmniTask)
    begin
      if Assigned(lAsyncFunc) then
        theResult := lAsyncFunc
      else if Assigned(lcAsyncFunc) then
        theResult := lcAsyncFunc(cancelToken);
    end;


  omniTask := CreateTask(task, 'VSoft.Async').Unobserved.OnTerminated(
    procedure (const task: IOmniTaskControl)
    var
      exc: Exception;
    begin
    //  terminated.Call(task);
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

    end);

  Parallel.ApplyConfig(taskConfig, omniTask);
  omniTask.Unobserved;
  Parallel.Start(omniTask, taskConfig);
  result := Self;
end;

constructor TAwaitable<TResult>.Create(const asyncFunc: TAsyncFunc<TResult, ICancellationToken>;const cancellationToken : ICancellationToken );
begin
  inherited Create;
  FCancellableAsyncFunc := asyncFunc;
  FAsyncFunc := nil;
  FCancellationToken := cancellationToken;
  Assert(FCancellationToken <> nil);
end;

constructor TAwaitable<TResult>.Create(const asyncFunc: TAsyncFunc<TResult>);
begin
  inherited Create;
  FCancellableAsyncFunc := nil;
  FAsyncFunc := asyncFunc;
  FCancellationToken := nil;
end;

function TAwaitable<TResult>.OnCancellation(const proc: TProc): IAwaitable<TResult>;
begin
  if Assigned(FAwaitProc) then
    raise Exception.Create('OnCancellation must be called before Await');
  if not Assigned(FCancellationToken) then
    raise Exception.Create('OnCancellation must only availeble if cancellation token passed in Async');


  FCancelProc := proc;
  result := Self;
end;

function TAwaitable<TResult>.OnException(const proc: TExceptionProc): IAwaitable<TResult>;
begin
  if Assigned(FAwaitProc) then
    raise Exception.Create('OnException must be called before Await');
  FExceptionProc := proc;
  result := Self;
end;



end.

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

{
 This is a simple wrapper around OmniThreadLibrart which extends it's async/await
 idea to allow cancellation and returning of results.

 Note we use our own cancellation token interface here so that we can avoid spreading
 omnithread everywhere. This could potentially wrap System.Threading for later versions
 of delphi if they ever implement cancellation tokens etc.
}

unit VSoft.Awaitable;

interface

uses
  System.SysUtils,
  VSoft.CancellationToken;

type
  //  aliases from VSoft.CancellationToken for backwards compatibility
  //  note that we register our own cancellationtoken class here that
  //  wraps the OmniThreadLibrary's cancellationtoken

  ///  ICancellationToken is passed to async methods
  ///  so that they can determin if the caller has
  ///  cancelled.
  ICancellationToken = VSoft.CancellationToken.ICancellationToken;

  //must be implemented by token classes
  ICancellationTokenManage = VSoft.CancellationToken.ICancellationTokenManage;

  /// This should be created by calling functions and a reference
  /// stored where it will not go out of scope.
  /// Pass the Token to async methods.
  ICancellationTokenSource = VSoft.CancellationToken.ICancellationTokenSource;

  //not cancellable
  TAsyncFunc<TResult> = reference to function : TResult;
  TAsyncProc = TProc;
  //cancellable
  TAsyncCancellableProc = reference to procedure(const cancelToken : ICancellationToken);
  TAsyncCancellableFunc<TResult> = reference to function(const cancelToken : ICancellationToken) : TResult;

  TResultProc<TResult> = reference to procedure(const value : TResult);

  TExceptionProc = reference to procedure(const e: Exception);

  IAwaitableGroup = interface
    function CancelAll: Boolean;
    function WaitForAll(maxWait_ms: cardinal = INFINITE): Boolean;
    function Any: Boolean;
    function IsEmpty: Boolean;
  end;

  IAwaitable = interface
    procedure Await(const proc: TProc);overload;
    ///  Called when an unhandled exception occurs in the async function
    ///  Note : must be called before Await.
    function OnException(const proc : TExceptionProc) : IAwaitable;


    function GroupedBy(const aGroup : IAwaitableGroup) : IAwaitable;

    ///  Called when the cancellation token is signalled.
    ///  Note : must be called before Await.
    function OnCancellation(const proc : TProc) : IAwaitable;

  end;

  /// This is returned from TAsync.Configure
  IAwaitable<TResult> = interface(IAwaitable)
    ///  Called when an unhandled exception occurs in the async function
    ///  Note : must be called before Await.
    function OnException(const proc : TExceptionProc) : IAwaitable<TResult>;

    ///  Called when the cancellation token is signalled.
    ///  Note : must be called before Await.
    function OnCancellation(const proc : TProc) : IAwaitable<TResult>;

    function GroupedBy(const aGroup : IAwaitableGroup) : IAwaitable<TResult>;

    ///  Runs the proc in the calling thread and provides the function result
    ///  as a parameter to the proc.
    procedure Await(const proc: TResultProc<TResult>);overload;
  end;

  TAsync = class
    class function Configure(const proc : TAsyncProc) : IAwaitable;overload;
    class function Configure(const proc : TAsyncCancellableProc; const cancellationToken : ICancellationToken) : IAwaitable;overload;
    class function Configure<TResult>(const func : TAsyncFunc<TResult>) : IAwaitable<TResult>;overload;
    class function Configure<TResult>(const func : TAsyncCancellableFunc<TResult>; const cancellationToken : ICancellationToken) : IAwaitable<TResult>;overload;
  end;

  /// Create a token source
  TCancellationTokenSourceFactory = class
    class function Create : ICancellationTokenSource;
  end;

  TAwaitableGroupFactory = class
  public
    class function New: IAwaitableGroup;
  end;

implementation

uses
  OtlSync,
  WinApi.Windows,
  VSoft.Awaitable.Impl;

type
  TCancellationToken = class(TCancellationTokenBase, ICancellationToken, ICancellationTokenManage, IOmniCancellationToken)
  private
    FOmniToken : IOmniCancellationToken;
  protected
    function  GetHandle: THandle;
    function  IsCancelled: boolean;
    function GetOmniToken : IOmniCancellationToken;
    procedure Cancel;
    procedure Reset;
    function WaitFor(Timeout: Cardinal): TWaitResult;
    property OmniToken : IOmniCancellationToken read GetOmniToken implements IOmniCancellationToken;
  public
    constructor Create;override;
  end;


class function TAsync.Configure(const proc: TAsyncProc): IAwaitable;
begin
  result := TAwaitable.Create(proc);
end;

class function TAsync.Configure(const proc: TAsyncCancellableProc; const cancellationToken: ICancellationToken): IAwaitable;
begin
  result := TAwaitable.Create(proc, cancellationToken);

end;

class function TAsync.Configure<TResult>(const func : TAsyncCancellableFunc<TResult>; const cancellationToken : ICancellationToken) : IAwaitable<TResult>;
begin
  result := TAwaitable<TResult>.Create(func, cancellationToken);
end;

class function TAsync.Configure<TResult>(const func : TAsyncFunc<TResult>) : IAwaitable<TResult>;
begin
  result := TAwaitable<TResult>.Create(func);
end;




{ TCancellationTokenSourceFactory }

class function TCancellationTokenSourceFactory.Create: ICancellationTokenSource;
begin
  result := VSoft.CancellationToken.TCancellationTokenSourceFactory.Create;
end;

{ TCancellationToken }

procedure TCancellationToken.Cancel;
begin
  FOmniToken.Signal;
end;

constructor TCancellationToken.Create;
begin
  FOmniToken := CreateOmniCancellationToken;
end;

function TCancellationToken.GetHandle: THandle;
begin
  result := FOmniToken.Handle;
end;

function TCancellationToken.IsCancelled: boolean;
begin
  result := FOmniToken.IsSignalled;
end;

procedure TCancellationToken.Reset;
begin
  FOmniToken.Clear;
end;

function TCancellationToken.WaitFor(Timeout: Cardinal): TWaitResult;
var
  h : THandle;
begin
  h := GetHandle;
  case WaitForMultipleObjectsEx(1, @h, True, Timeout, False) of
    WAIT_ABANDONED: Result := TWaitResult.wrAbandoned;
    WAIT_OBJECT_0: Result := TWaitResult.wrSignaled;
    WAIT_TIMEOUT: Result := TWaitResult.wrTimeout;
    WAIT_FAILED: Result := TWaitResult.wrError;
  else
    Result := TWaitResult.wrError;
  end;
end;

function TCancellationToken.GetOmniToken: IOmniCancellationToken;
begin
  result := FOmniToken;
end;


{ TAwaitableGroupFactory }

class function TAwaitableGroupFactory.New: IAwaitableGroup;
begin
  Result := VSoft.Awaitable.Impl.TAwaitableGroupFactory.New;
end;

initialization
  VSoft.CancellationToken.TCancellationTokenSourceFactory.RegisterTokenClass(VSoft.Awaitable.TCancellationToken);

end.

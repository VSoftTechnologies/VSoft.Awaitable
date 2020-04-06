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
  SysUtils;

type
  ///  ICancellationToken is passed to async methods
  ///  so that they can determin if the caller has
  ///  cancelled.
  ICancellationToken = interface
  ['{481A7D4C-60D2-4AE5-AE14-F2298E89B638}']
    function  GetHandle: THandle;
    function  IsCancelled: boolean;

    //Note : do not call SetEvent on this handle
    //as it will result in IsSignalled prop
    //returning incorrect results.
    property Handle: THandle read GetHandle;
  end;


  /// This should be created by calling functions and a reference
  /// stored where it will not go out of scope.
  /// Pass the Token to async methods.
  ICancellationTokenSource = interface
  ['{4B7627AE-E8CE-4857-90D7-3C6D5B8A4F9F}']
    procedure Reset;
    procedure Cancel;
    function Token : ICancellationToken;
  end;

  //not cancellable
  TAsyncFunc<TResult> = reference to function : TResult;
  TAsyncProc = TProc;
  //cancellable
  TAsyncCancellableProc = reference to procedure(const cancelToken : ICancellationToken);
  TAsyncCancellableFunc<TResult> = reference to function(const cancelToken : ICancellationToken) : TResult;

  TResultProc<TResult> = reference to procedure(const value : TResult);

  TExceptionProc = reference to procedure(const e: Exception);

  IAwaitable = interface
    procedure Await(const proc: TProc);overload;
    ///  Called when an unhandled exception occurs in the async function
    ///  Note : must be called before Await.
    function OnException(const proc : TExceptionProc) : IAwaitable;

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

  TCancellationTokenSourceFactory = class
    class function Create : ICancellationTokenSource;
  end;


implementation

uses
  OtlSync,
  VSoft.Awaitable.Impl;

type
  TCancellationToken = class(TInterfacedObject, ICancellationToken, IOmniCancellationToken)
  private
    FOmniToken : IOmniCancellationToken;
  protected
    function  GetHandle: THandle;
    function  IsCancelled: boolean;
    function GetOmniToken : IOmniCancellationToken;
    property OmniToken : IOmniCancellationToken read GetOmniToken implements IOmniCancellationToken;
  public
    constructor Create(const omniToken : IOmniCancellationToken);
  end;

  TCancellationTokenSource = class(TInterfacedObject, ICancellationTokenSource )
  private
    FOmniToken : IOmniCancellationToken;
    FToken : ICancellationToken;
  protected
    procedure Reset;
    procedure Cancel;
    function Token : ICancellationToken;
  public
    constructor Create;
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
  result := TCancellationTokenSource.Create;
end;

{ TCancellationToken }

constructor TCancellationToken.Create(const omniToken: IOmniCancellationToken);
begin
  FOmniToken := omniToken;
end;

function TCancellationToken.GetHandle: THandle;
begin
  result := FOmniToken.Handle;
end;

function TCancellationToken.IsCancelled: boolean;
begin
  result := FOmniToken.IsSignalled;
end;

function TCancellationToken.GetOmniToken: IOmniCancellationToken;
begin
  result := FOmniToken;
end;


{ TCancellationTokenSource }

procedure TCancellationTokenSource.Reset;
begin
  FOmniToken.Clear;
end;

constructor TCancellationTokenSource.Create;
begin
  FOmniToken := CreateOmniCancellationToken;
  FToken := TCancellationToken.Create(FOmniToken);
end;


procedure TCancellationTokenSource.Cancel;
begin
  FOmniToken.Signal;
end;

function TCancellationTokenSource.Token: ICancellationToken;
begin
  result := FToken;
end;

end.

# VSoft.Awaitable

This is a simple library for making Asynchronous function calls. It is a wrapper over [OmniThreadLibrary](https://github.com/gabr42/OmniThreadLibrary) and is based on it's own Parallel.Async functionality.

Parallel.Async does not provide a simple way to cancel calls, and be notified of the cancellation, and it does not allow the returning of results.

## Usage

Include VSoft.Awaitable in your uses clause.

```delphi
    TAsync.Configure<string>(
        function (const cancelToken : ICancellationToken) : string
        var
          i: Integer;
        begin
            result := 'Hello ' + value;
            for i := 0 to 2000 do
            begin
              Sleep(1);
              //in loops, check the token
              if cancelToken.IsCancelled then
                exit;
            end;

            //where api's can take a handle for cancellation, use the token.handle
            WaitForSingleObject(cancelToken.Handle,5000);

            //any unhandled exceptions here will result in the on exception proc being called (if configured)
            //raise Exception.Create('Error Message');
        end, token);
    )
    .OnException(
        procedure (const e : Exception)
        begin
          Label1.Caption := e.Message;
        end)
    .OnCancellation(
        procedure
        begin
            //clean up
            Label1.Caption := 'Cancelled';
        end)
    .Await(
        procedure (const value : string)
        begin
            //use result
            Label1.Caption := value;
        end);

```

You can also return `IAwaitable<TResult>` from functions

```delphi
function LoadAsyncWithToken (const token : ICancellationToken; const value : string) : IAwaitable<string>;
begin
  //configure our async call and return the IAwaitable<string>
  result := TAsync.Configure<string>(
        function(const cancelToken : ICancellationToken) : string
        begin
            //.... do some long running thing
            result := 'Hello ' + value;
        end, token);
end;

// for when there is no result to return
function RunIt (const token : ICancellationToken; const value : string) : IAwaitable;
begin
  //configure our async call and return the IAwaitable<string>
  result := TAsync.Configure(
        procedure(const cancelToken : ICancellationToken)
        begin
        //.... do some long running thing
        end, token);
end;


procedure UseIt;
begin
     LoadAsyncWithToken('param', FTokenSource.Token)
     .OnException(
        procedure (const e : Exception)
        begin
          Label1.Caption := e.Message;
        end)
    .OnCancellation(
        procedure
        begin
            //clean up
            Label1.Caption := 'Cancelled';
        end)
    .Await(
        procedure (const value : string)
        begin
            //use result
            Label1.Caption := value;
        end);

     RunIt('param', FTokenSource.Token)
     .OnException(
        procedure (const e : Exception)
        begin
          Label1.Caption := e.Message;
        end)
    .OnCancellation(
        procedure
        begin
            //clean up
            Label1.Caption := 'Cancelled';
        end)
    .Await(
        procedure
        begin
            //use result
            Label1.Caption := 'Done';
        end);


```

Note that Await actually invokes the async function. There is also an overload to TAsync.Configure that does not take a cancellation token for when you don't need to cancel.
Delphinus-Support

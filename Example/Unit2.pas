unit Unit2;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes, Vcl.Graphics,
  Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls, VSoft.Awaitable;

type
  TForm2 = class(TForm)
    Button1: TButton;
    Label1: TLabel;
    Button2: TButton;
    procedure Button1Click(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure Button2Click(Sender: TObject);
  private
    { Private declarations }
    FCancellationTokenSource : ICancellationTokenSource;
  public
    { Public declarations }
  end;

var
  Form2: TForm2;

implementation

{$R *.dfm}


function LoadAsync(const value : string) : IAwaitable<string>;
begin
  //configure our async call and return the IAwaitable<string>
  result := TAsync.Configure<string>(
        function() : string
        begin
            Sleep(2000);
            result := 'Hello ' + value;
            raise Exception.Create('Error Message');
        end);
end;

function LoadAsyncWithToken(const token : ICancellationToken; const value : string) : IAwaitable<string>;
begin
  //configure our async call and return the IAwaitable<string>
  result := TAsync.Configure<string>(
        function(const cancelToken : ICancellationToken) : string
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

            //any unhandled exceptions here will result in the on exception pro being called (if configured)

            //raise Exception.Create('Error Message');
        end, token);
end;




procedure TForm2.Button1Click(Sender: TObject);
begin
  FCancellationTokenSource.Reset;
  Label1.Caption := 'Loading';

  //LoadAsync('vincent')
  LoadAsyncWithToken(FCancellationTokenSource.Token, 'vincent')
      .OnException(
        procedure(const e : Exception)
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
        procedure(const value : string)
        begin
          //use result
          Label1.Caption := value;
        end);

end;

procedure TForm2.Button2Click(Sender: TObject);
begin
  FCancellationTokenSource.Cancel;
end;

procedure TForm2.FormCreate(Sender: TObject);
begin
  FCancellationTokenSource := TCancellationTokenSourceFactory.Create;
end;

end.

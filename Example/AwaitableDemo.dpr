program AwaitableDemo;

uses
  Vcl.Forms,
  Unit2 in 'Unit2.pas' {Form2},
  VSoft.Awaitable in '..\Source\VSoft.Awaitable.pas',
  VSoft.Awaitable.Impl in '..\Source\VSoft.Awaitable.Impl.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TForm2, Form2);
  Application.Run;
end.

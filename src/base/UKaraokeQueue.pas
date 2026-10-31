{* UltraStar Deluxe - Karaoke Queue
 *
 * Modo karaoke con cola externa. Comunicacion por archivos de texto en la
 * carpeta "karaoke" junto al ejecutable (o la que indique la variable de
 * entorno USDX_KARAOKE_DIR). Si la carpeta no existe, USDX funciona normal.
 *
 *   next.txt    lo escribe el servidor: proximo tema a cantar
 *   playing.txt USDX renombra next.txt a playing.txt al tomarlo
 *   result.txt  lo escribe USDX al terminar (puntaje o abortado)
 *
 * Formato: lineas clave=valor en UTF-8.
 *   id=17
 *   file=C:\USDX\songs\Artista - Tema\Artista - Tema.txt
 *   artist=Artista
 *   title=Tema
 *   players=2
 *   name1=Ana
 *   name2=Juan
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *}

unit UKaraokeQueue;

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

uses
  Classes,
  SysUtils,
  UPath;

type
  TKaraokeRequest = record
    Id:       UTF8String;
    SongFile: UTF8String;
    Artist:   UTF8String;
    Title:    UTF8String;
    Names:    array of UTF8String;
  end;

const
  KARAOKE_START_DELAY_MS = 6000;  // tiempo para que el cantante agarre el micro
  KARAOKE_SCORE_SHOW_MS  = 12000; // cuanto se muestra el puntaje antes de volver

var
  KaraokeCurrentId:       UTF8String = '';  // tema arrancado desde la cola, esperando resultado
  KaraokePendingSong:     integer = -1;     // indice en CatSongs esperando arrancar
  KaraokePendingTime:     cardinal = 0;
  KaraokePendingId:       UTF8String = '';
  KaraokeScoreAutoReturn: boolean = false;
  KaraokeScoreShownTime:  cardinal = 0;

function  KaraokeActive: boolean;
function  KaraokeHasPending: boolean;
function  KaraokePollRequest(out Req: TKaraokeRequest): boolean;
function  KaraokeFindSong(const Req: TKaraokeRequest): integer;
procedure KaraokeApplyPlayers(const Req: TKaraokeRequest);
procedure KaraokeWriteResult(const Id: UTF8String; const Status: UTF8String);

implementation

uses
  sdl2,
  UAvatars,
  UIni,
  ULog,
  UNote,
  UPlatform,
  USong,
  USongs,
  UThemes,
  UCommon;

const
  POLL_MS = 1000;

var
  KDir:        IPath = nil;
  LastPoll:    cardinal = 0;
  LastPending: cardinal = 0;
  LastEnabled: boolean = false;

function GetDir: IPath;
var
  EnvDir: string;
begin
  if KDir = nil then
  begin
    EnvDir := GetEnvironmentVariable('USDX_KARAOKE_DIR');
    if EnvDir <> '' then
      KDir := Path(EnvDir)
    else
      KDir := Platform.GetExecutionDir.Append('karaoke');
    Log.LogStatus('Karaoke: carpeta de cola ' + KDir.ToNative, 'UKaraokeQueue');
  end;
  Result := KDir;
end;

function KaraokeActive: boolean;
begin
  Result := GetDir.IsDirectory;
  if Result <> LastEnabled then
  begin
    LastEnabled := Result;
    if Result then
      Log.LogStatus('Karaoke: modo cola ACTIVADO', 'UKaraokeQueue')
    else
      Log.LogStatus('Karaoke: modo cola desactivado (no existe la carpeta)', 'UKaraokeQueue');
  end;
end;

// Hay un pedido esperando (next.txt) y todavia no lo tomamos.
// Lo usan las otras pantallas para saltar solas a la seleccion de temas.
// Devuelve true como mucho una vez cada 3 segundos, para no disparar
// varios cambios de pantalla durante el fundido.
function KaraokeHasPending: boolean;
begin
  Result := false;
  if (SDL_GetTicks - LastPending) < POLL_MS then
    Exit;
  LastPending := SDL_GetTicks;
  if not KaraokeActive then
    Exit;
  Result := GetDir.Append('next.txt').Exists;
  if Result then
    LastPending := SDL_GetTicks + 3000;
end;

function LoadKV(const F: IPath): TStringList;
var
  Stream: TBinaryFileStream;
begin
  Result := TStringList.Create;
  try
    Stream := TBinaryFileStream.Create(F, fmOpenRead or fmShareDenyNone);
    try
      Result.LoadFromStream(Stream);
    finally
      Stream.Free;
    end;
    // quitar BOM UTF-8 si lo hay
    if (Result.Count > 0) and (Copy(Result[0], 1, 3) = #$EF#$BB#$BF) then
      Result[0] := Copy(Result[0], 4, MaxInt);
  except
    on E: Exception do
    begin
      Log.LogError('Karaoke: no pude leer ' + F.ToNative + ': ' + E.Message, 'UKaraokeQueue');
      FreeAndNil(Result);
    end;
  end;
end;

procedure SaveKV(L: TStringList; const FileName: UTF8String);
var
  Tmp, Dest: IPath;
  Stream: TBinaryFileStream;
begin
  Tmp := GetDir.Append(FileName + '.tmp');
  Dest := GetDir.Append(FileName);
  try
    Stream := TBinaryFileStream.Create(Tmp, fmCreate);
    try
      L.SaveToStream(Stream);
    finally
      Stream.Free;
    end;
    if Dest.Exists then
      Dest.DeleteFile;
    if not Tmp.Rename(Dest) then
      Log.LogError('Karaoke: no pude renombrar ' + Tmp.ToNative, 'UKaraokeQueue');
  except
    on E: Exception do
      Log.LogError('Karaoke: no pude escribir ' + Dest.ToNative + ': ' + E.Message, 'UKaraokeQueue');
  end;
end;

function KaraokePollRequest(out Req: TKaraokeRequest): boolean;
var
  F, P: IPath;
  L:    TStringList;
  N, I: integer;
begin
  Result := false;
  Req.Id := '';
  SetLength(Req.Names, 0);

  if (SDL_GetTicks - LastPoll) < POLL_MS then
    Exit;
  LastPoll := SDL_GetTicks;

  if not KaraokeActive then
    Exit;

  F := GetDir.Append('next.txt');
  if not F.Exists then
    Exit;

  L := LoadKV(F);
  if L = nil then
    Exit;
  try
    Req.Id       := Trim(L.Values['id']);
    Req.SongFile := Trim(L.Values['file']);
    Req.Artist   := Trim(L.Values['artist']);
    Req.Title    := Trim(L.Values['title']);
    N := StrToIntDef(L.Values['players'], 1);
    if N < 1 then N := 1;
    if N > IMaxPlayerCount then N := IMaxPlayerCount;
    SetLength(Req.Names, N);
    for I := 0 to N - 1 do
      Req.Names[I] := Trim(L.Values['name' + IntToStr(I + 1)]);
  finally
    L.Free;
  end;

  // marcar como tomado: next.txt -> playing.txt
  P := GetDir.Append('playing.txt');
  if P.Exists then
    P.DeleteFile;
  if not F.Rename(P) then
  begin
    Log.LogError('Karaoke: no pude tomar next.txt', 'UKaraokeQueue');
    Exit;
  end;

  Log.LogStatus('Karaoke: pedido ' + Req.Id + ' -> ' + Req.Artist + ' - ' + Req.Title, 'UKaraokeQueue');
  Result := Req.Id <> '';
end;

function KaraokeFindSong(const Req: TKaraokeRequest): integer;
var
  I:      integer;
  Target: IPath;
  S:      TSong;
begin
  Result := -1;
  if Length(CatSongs.Song) = 0 then
    Exit;

  // 1) por ruta del archivo
  if Req.SongFile <> '' then
  begin
    Target := Path(Req.SongFile);
    for I := 0 to High(CatSongs.Song) do
    begin
      S := CatSongs.Song[I];
      if S.Main or (S.Path = nil) or (S.FileName = nil) then
        Continue;
      if S.Path.Append(S.FileName).Equals(Target, true) then
      begin
        Result := I;
        Exit;
      end;
    end;
  end;

  // 2) por artista + titulo
  for I := 0 to High(CatSongs.Song) do
  begin
    S := CatSongs.Song[I];
    if S.Main then
      Continue;
    if (WideCompareText(UTF8Decode(S.Artist), UTF8Decode(Req.Artist)) = 0) and
       (WideCompareText(UTF8Decode(S.Title), UTF8Decode(Req.Title)) = 0) then
    begin
      Result := I;
      Exit;
    end;
  end;
end;

procedure KaraokeApplyPlayers(const Req: TKaraokeRequest);
var
  N, I, CountIndex: integer;
  Nm:  UTF8String;
  Col: TRGB;
begin
  // un jugador por nombre recibido; los duos con un solo jugador los maneja USDX
  N := Length(Req.Names);
  if N < 1 then N := 1;

  // cantidad valida de jugadores (1, 2, 3, 4, 6)
  CountIndex := High(IPlayersVals);
  for I := 0 to High(IPlayersVals) do
    if IPlayersVals[I] >= N then
    begin
      CountIndex := I;
      Break;
    end;

  Ini.Players := CountIndex;
  PlayersPlay := IPlayersVals[CountIndex];
  SetLength(Player, PlayersPlay);

  for I := 0 to PlayersPlay - 1 do
  begin
    if (I < Length(Req.Names)) and (Req.Names[I] <> '') then
      Nm := Req.Names[I]
    else
      Nm := 'Jugador ' + IntToStr(I + 1);

    Ini.Name[I] := Nm;
    Player[I].Name := Nm;
    Player[I].Level := Ini.PlayerLevel[I];

    // sin avatar, con el color configurado de cada jugador
    if Assigned(NoAvatarTexture[I + 1]) then
    begin
      AvatarPlayerTextures[I + 1] := NoAvatarTexture[I + 1];
      Col := GetPlayerColor(Ini.PlayerColor[I]);
      AvatarPlayerTextures[I + 1].ColR := Col.R;
      AvatarPlayerTextures[I + 1].ColG := Col.G;
      AvatarPlayerTextures[I + 1].ColB := Col.B;
    end;
  end;
end;

procedure KaraokeWriteResult(const Id: UTF8String; const Status: UTF8String);
var
  L: TStringList;
  I: integer;
  P: IPath;
begin
  if Id = '' then
    Exit;
  L := TStringList.Create;
  try
    L.Add('id=' + Id);
    L.Add('status=' + Status); // ok | aborted | notfound
    L.Add('players=' + IntToStr(Length(Player)));
    for I := 0 to High(Player) do
    begin
      L.Add('name' + IntToStr(I + 1) + '=' + Player[I].Name);
      L.Add('score' + IntToStr(I + 1) + '=' + IntToStr(Player[I].ScoreTotalInt));
    end;
    SaveKV(L, 'result.txt');
  finally
    L.Free;
  end;

  P := GetDir.Append('playing.txt');
  if P.Exists then
    P.DeleteFile;

  Log.LogStatus('Karaoke: resultado ' + Id + ' (' + Status + ')', 'UKaraokeQueue');
end;

end.

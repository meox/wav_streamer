%% WAV file streamer

-module(wav_streamer).
-export([
  stream_rtp_flow/2,
  send_file_to/4,
  open_wave/1,
  make_rtp_packet/5,
  framing/1, framing/3
]).

-define(PCM_TAG, 1).
-define(FMT_CHUNK_SIZE, 16).


stream_rtp_flow(FileName, RtpPort) ->
  {ok, Socket} = gen_udp:open(0),
  {ok, File, Header} = open_wave(FileName),
  ok = send_file_to(File, Header, Socket, RtpPort),
  file:close(File),
  gen_udp:close(Socket),
  ok.

open_wave(FileName) ->
  case file:open(FileName, [read, binary]) of
    {ok, F} ->
      {ok, F, read_header(F)};
    E -> E
  end.

read_header(F) ->
  % "RIFF" 4 byets
  % cksize 4 bytes
  % "WAVE" 4 byte
  {ok, <<"RIFF", _CkSize:32/little-integer, "WAVE">>} = file:read(F, 12),
  % fmt section
  {ok, <<"fmt ", ?FMT_CHUNK_SIZE:32/little-integer>>} = file:read(F, 8),
  % wFormatTag 	2 	Format code
	% nChannels 	2 	Number of interleaved channels
	% nSamplesPerSec 	4 	Sampling rate (blocks per second)
	% nAvgBytesPerSec 	4 	Data rate
	% nBlockAlign 	2 	Data block size (bytes)
	% wBitsPerSample 	2 	Bits per sample
  {ok, <<
    ?PCM_TAG:16/little-integer,
    NChannels:16/little-integer,
    NSamplesPerSec:32/little-integer,
    NAvgBytesPerSec:32/little-integer,
    NBlockAlign:16/little-integer,
    WBitsPerSample:16/little-integer>>
  } = file:read(F, ?FMT_CHUNK_SIZE),
  Header = #{
    "channels" => NChannels,
    "samples_sec" => NSamplesPerSec,
    "bytes_sec" => NAvgBytesPerSec,
    "block_align" => NBlockAlign,
    "bits_sample" => WBitsPerSample
  },
  % next chunk (expecting LIST)
  {ok, NextChunk} = file:read(F, 4),
  InfoHeader = parse_header_chunk(NextChunk, F, Header),
  % next chunk (expecting data)
  {ok, NextChunkData} = file:read(F, 4),
  parse_header_chunk(NextChunkData, F, InfoHeader).

parse_header_chunk(<<"LIST">>, F, PartialHeader) ->
  {ok, <<InfoSize:32/little-integer, "INFO">>} = file:read(F, 8),
  {ok, InfoData} = file:read(F, InfoSize-4),
  PartialHeader#{"info_size" => InfoSize, "info" => parse_info_list(InfoData)};

parse_header_chunk(<<"data">>, F, PartialHeader) ->
  {ok, <<DataSize:32/little-integer>>} = file:read(F, 4),
  PartialHeader#{"data_size" => DataSize}.

parse_info_list(InfoData) ->
  parse_info_list(InfoData, []).

-spec parse_info_list(binary(), [{string(), string()}]) -> [{string(), string()}].
parse_info_list(<<>>, Acc) -> Acc;
parse_info_list(InfoData, Acc) ->
  <<Tag:4/binary, Size:32/little-integer, Text:Size/binary, Rest/binary>> = InfoData,
  % all text should be word aligned
  Align = 2,
  Padding = (Align - (Size rem Align)) rem Align,
  parse_info_list(
    remove_padding(Rest, Padding),
    [{binary_to_list(Tag), binary_to_list(Text)} | Acc]
  ).

make_rtp_packet(SSRC, Ts, Seq, Header, Payload) ->
  V = 2, % rtp version
  P = 0, % padding
  X = 0, % extension
  CC = 0, % the CSRC count contains the number of CSRC identifiers that follow the fixed header
  M = 0,
  PT = payload_type(Header),
  BEPayload = convert_to_big(Payload),
  <<V:2/big, P:1, X:1, CC:4/big, M:1, PT:7/big, Seq:16/big, Ts:32/big, SSRC:32/big, BEPayload/binary>>.

make_rtp_packets(SSRC, Ts, Seq, Header, Frames) ->
  make_rtp_packets(SSRC, Ts, Seq, Header, Frames, [], 0).

make_rtp_packets(_SSRC, _Ts, _Seq, _Header, [], Acc, TotDelta) -> {lists:reverse(Acc), TotDelta};
make_rtp_packets(SSRC, Ts, Seq, Header, [Frame | Rest], Acc, TotDelta) ->
  Packet = make_rtp_packet(SSRC, Ts, Seq, Header, Frame),
  TSDelta = round(byte_size(Packet) / 4),
  make_rtp_packets(SSRC, Ts+TSDelta, Seq+1, Header, Rest, [Packet | Acc], TotDelta + TSDelta).

send_file_to(File, Header, Socket, RtpPort) ->
  SSRC = rand:uniform(1000000),
  Seq = random_init_seq(),
  InitTs = erlang:system_time(millisecond),
  send_file_to(SSRC, File, Header, Socket, RtpPort, 0, Seq, InitTs).

send_file_to(SSRC, File, Header, Socket, RtpPort, Counter, Seq, Ts) ->
  case read_chunk_from_file(File) of
    {ok, Data} ->
      % create a RDP bucket
      Frames = framing(Data),
      {Packets, TSDelta} = make_rtp_packets(SSRC, Ts, Seq, Header, Frames),
      % send Data to the dest Socket
      ok = send_packets(Socket, RtpPort, Packets),
      % sleep
      timer:sleep(22),
      % loop
      NPackets = length(Packets),
      NexTS = Ts + TSDelta,
      send_file_to(SSRC, File, Header, Socket, RtpPort, Counter + NPackets, Seq + NPackets, NexTS);
    eof ->
      ok;
    Error -> Error
  end.

read_chunk_from_file(File) ->
   MaxBytes = 4*1024,
   file:read(File, MaxBytes).

send_packets(_Socket, _RtpPort, []) -> ok;
send_packets(Socket, RtpPort, [Packet | Others]) ->
  ok = gen_udp:send(Socket, {127, 0, 0, 1}, RtpPort, Packet),
  send_packets(Socket, RtpPort, Others).

random_init_seq() -> rand:uniform(1000000).

% see: https://datatracker.ietf.org/doc/html/rfc3551
%
% PT | Media       |     HS    | Channels  |
% ___|_____________|_______________________|
%10  | L16         |   44,100  |     2     |
%11  | L16         |   44,100  |     1     |
payload_type(#{"channels" := 2, "samples_sec" := 44100}) ->
  10;
payload_type(#{"channels" := 1, "samples_sec" := 44100}) ->
  11.

convert_to_big(Data) ->
  convert_to_big(Data, <<>>).

convert_to_big(<<>>, Acc) -> Acc;
convert_to_big(Data, Acc) ->
  <<C1:16/little, C2:16/little, Rest/binary>> = Data,
  convert_to_big(Rest, <<Acc/binary, C1:16/big, C2:16/big>>).

  -spec remove_padding(binary(), integer()) -> binary().
remove_padding(Data, 0) -> Data;
remove_padding(Data, N) ->
  <<_Discard:N/binary-unit:8, Rest/binary>> = Data,
  Rest.

framing(Payload) ->
  MaxPayloadSize = 1460,
  lists:reverse(framing(Payload, MaxPayloadSize, [])).

framing(<<>>, _MaxPayloadSize, Acc) -> Acc;
framing(Payload, MaxPayloadSize, Acc) when MaxPayloadSize =< byte_size(Payload) ->
  <<Frame:MaxPayloadSize/binary-unit:8, Rest/binary>> = Payload,
  framing(Rest, MaxPayloadSize, [Frame | Acc]);
framing(Payload, _MaxPayloadSize, Acc) ->
  [Payload | Acc].

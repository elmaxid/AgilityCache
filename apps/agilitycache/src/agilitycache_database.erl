-module(agilitycache_database).

-include("include/cache.hrl").

-export([read_cached_file_info/3,
         write_cached_file_info/3,
         read_preliminar_info/2,
         read_remaining_info/2,
         write_info/2
        ]).

%-compile(export_all).

read_preliminar_info(FileId, CachedFileInfo) ->
  try
    {ok, CachedFileInfo0} = read_cached_file_info(FileId, <<"age">>, CachedFileInfo),
    {ok, _CachedFileInfo1} = read_cached_file_info(FileId, <<"max_age">>, CachedFileInfo0)
  of
    {ok, _} = Rtr ->
      Rtr
  catch
    error:Error ->
      {error, Error}
  end.

%% Assumo que já leu o preliminar info
read_remaining_info(FileId, CachedFileInfo) ->
  try
    {ok, _CachedFileInfo0} = read_cached_file_info(FileId, <<"headers">>, CachedFileInfo)
  of
    {ok, _} = Rtr ->
      Rtr
  catch
    error:Error ->
      {error, Error}
  end.

read_cached_file_info(FileId, Info, CachedFileInfo) ->
  case find_file(FileId, Info) of
    {error, _} = Error ->
      Error;
    {ok, Path} ->
      case file:read_file(Path) of
        {ok, Data} ->
          {ok, _} = parse_data(Info, Data, CachedFileInfo);
        {error, _ } = Error0 ->
          Error0
      end
  end.
write_cached_file_info(FileId, Info, CachedFileInfo) ->
  Path = case find_file(FileId, Info) of
    {ok, Path1} ->
      Path1;
    {error, _} ->
      Paths = agilitycache_utils:get_app_env(database, undefined),
      {ok, BestPath} = agilitycache_path_chooser:get_best_path(Paths),
      SubPath = get_subpath(FileId),
      filename:join([BestPath, SubPath, Info])
  end,
  filelib:ensure_dir(Path),
  Data = generate_data(Info, CachedFileInfo),
  case file:write_file(Path, Data) of
    {error, _} = Error0 ->
      Error0;
    ok ->
      ok
  end.

write_info(FileId, CachedFileInfo) ->
  ok = write_cached_file_info(FileId, <<"headers">>, CachedFileInfo),
  ok = write_cached_file_info(FileId, <<"status_code">>, CachedFileInfo),
  ok = write_cached_file_info(FileId, <<"max_age">>, CachedFileInfo),
  ok = write_cached_file_info(FileId, <<"age">>, CachedFileInfo),
  ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

generate_data(<<"headers">>, #cached_file_info { http_rep = #http_rep { headers = Headers } }) ->
  Headers0 = [<< Key/binary, ": ", Value/binary, "\r\n" >> || {Key, Value} <- Headers],
  Headers0;

generate_data(<<"status_code">>, #cached_file_info { http_rep = #http_rep { status = Status } }) ->
  integer_to_list(list_to_binary(Status));

generate_data(<<"max_age">>, #cached_file_info { max_age = MaxAge } ) ->
  {ok, MaxAge0} = agilitycache_date_time:generate_simple_string(MaxAge),
  MaxAge0;

generate_data(<<"age">>, #cached_file_info { age = Age } ) ->
  {ok, Age0} = agilitycache_date_time:generate_simple_string(Age),
  Age0.

decode_headers(Data, CachedFileInfo) ->
  case erlang:decode_packet(httph_bin, Data, []) of
    {ok, Header, Rest} ->
      parse_headers(Header, CachedFileInfo, Rest);
    Error ->
      {error, Error}
  end.

parse_data(<<"headers">>, Data, CachedFileInfo) ->
  decode_headers(<<Data/binary, "\r\n">>, CachedFileInfo);

parse_data(<<"status_code">>, Data, CachedFileInfo = #cached_file_info { http_rep = Rep }) ->
  try list_to_integer(binary_to_list(Data)) of
    Status ->
      {ok, CachedFileInfo#cached_file_info{ http_rep = Rep#http_rep{ status = Status }}}
  catch
    error:_ ->
      {error, <<"algum erro">>}
  end;
parse_data(<<"max_age">>, Data, CachedFileInfo) ->
  case agilitycache_date_time:parse_simple_string(Data) of
    {error, _} = Error ->
      Error;
    {ok, DateTime} ->
      {ok, CachedFileInfo#cached_file_info{ max_age = DateTime }}
  end;

parse_data(<<"age">>, Data, CachedFileInfo) ->
  case agilitycache_date_time:parse_simple_string(Data) of
    {error, _} = Error ->
      Error;
    {ok, DateTime} ->
      {ok, CachedFileInfo#cached_file_info{ age = DateTime }}
  end.

%%-spec find_file(binary(), binary())
%% FileId is a md5sum in binary format
%% Devo aceitar mais de uma localização?
find_file(FileId, Extension) ->
  Paths1 = agilitycache_utils:get_app_env(database, undefined),
  Paths2 = lists:map(fun(X) -> proplists:get_value(path, X) end, Paths1),
  SubPath = get_subpath(FileId),
  FilePaths = lists:map(fun(X) -> filename:join([X, SubPath, Extension]) end, Paths2),
  FoundPaths = [FileFound || FileFound <- FilePaths, filelib:is_regular(FileFound)],
  case FoundPaths of
    [] ->
      {error, notfound};
    _ ->
      {ok, erlang:hd(FoundPaths)}
  end.

get_subpath(FileId) ->
  HexFileId = agilitycache_utils:hexstring(FileId),
  filename:join([io_lib:format("~c", [binary:at(HexFileId, 1)]), io_lib:format("~c", [binary:at(HexFileId, 20)]), HexFileId]).

parse_headers({http_header, _I, Field, _R, Value}, CachedFileInfo = #cached_file_info{ http_rep = Rep }, Rest) ->
  Field2 = agilitycache_http_protocol_parser:format_header(Field),
  Rep2 = Rep#http_rep{headers=[{Field2, Value}|Rep#http_rep.headers]},
  decode_headers(Rest, CachedFileInfo#cached_file_info { http_rep = Rep2 });
parse_headers(http_eoh, CachedFileInfo, _Rest) ->
  %% Ok, terminar aqui, e esperar envio!
  {ok, CachedFileInfo};
parse_headers({http_error, _Bin}, _CachedFileInfo, _Rest) ->
  {error, <<"Erro parse headers">>}.


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
get_subpath_test_() ->
  %% FileId, Subpath
  Tests = [
      {<<43,87,61,146,28,153,56,102,46,185,70,221,175,97,55,123>>, <<"B/4/2B573D921C9938662EB946DDAF61377B">>},
      {<<0,16,84,246,205,210,177,250,245,54,169,8,245,163,25,203>>, <<"0/A/001054F6CDD2B1FAF536A908F5A319CB">>}
      ],
  [{H, fun() -> R = get_subpath(H) end} || {H, R} <- Tests].
-endif.


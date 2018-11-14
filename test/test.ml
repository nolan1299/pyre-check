(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core
open OUnit2

open Analysis
open Ast
open Pyre
open PyreParser
open Statement


let initialize () =
  Memory.get_heap_handle (Configuration.Analysis.create ())
  |> ignore;
  Log.initialize_for_tests ();
  Statistics.disable ();
  Type.Cache.disable ()


let () =
  initialize ()


let trim_extra_indentation source =
  let is_non_empty line =
    not (String.for_all ~f:Char.is_whitespace line) in
  let minimum_indent lines =
    let indent line =
      String.to_list line
      |> List.take_while ~f:Char.is_whitespace
      |> List.length in
    List.filter lines ~f:is_non_empty
    |> List.map ~f:indent
    |> List.fold ~init:Int.max_value ~f:Int.min in
  let strip_line minimum_indent line =
    if not (is_non_empty line) then
      line
    else
      String.slice line minimum_indent (String.length line) in
  let strip_lines minimum_indent = List.map ~f:(strip_line minimum_indent) in
  let lines =
    String.rstrip source
    |> String.split ~on:'\n' in
  let minimum_indent = minimum_indent lines in
  strip_lines minimum_indent lines
  |> String.concat ~sep:"\n"


let run tests =
  let rec bracket test =
    let bracket_test test context =
      initialize ();
      test context;
      Unix.unsetenv "HH_SERVER_DAEMON_PARAM";
      Unix.unsetenv "HH_SERVER_DAEMON"
    in
    match test with
    | OUnitTest.TestLabel (name, test) ->
        OUnitTest.TestLabel (name, bracket test)
    | OUnitTest.TestList tests ->
        OUnitTest.TestList (List.map tests ~f:bracket)
    | OUnitTest.TestCase (length, f) ->
        OUnitTest.TestCase (length, bracket_test f)
  in
  tests
  |> bracket
  |> run_test_tt_main


let parse_untrimmed
    ?(handle = "test.py")
    ?(qualifier = [])
    ?(debug = true)
    ?(strict = false)
    ?(declare = false)
    ?(version = 3)
    ?(autogenerated = false)
    ?(silent = false)
    ?(docstring = None)
    ?(ignore_lines = [])
    source =
  let handle = File.Handle.create handle in
  let buffer = Lexing.from_string (source ^ "\n") in
  buffer.Lexing.lex_curr_p <- {
    buffer.Lexing.lex_curr_p with
    Lexing.pos_fname = File.Handle.show handle;
  };
  try
    let source =
      let state = Lexer.State.initial () in
      let metadata =
        Source.Metadata.create
          ~autogenerated
          ~debug
          ~declare
          ~ignore_lines
          ~strict
          ~version
          ~number_of_lines:(-1)
          ()
      in
      Source.create
        ~docstring
        ~metadata
        ~handle
        ~qualifier
        (Generator.parse (Lexer.read state) buffer)
    in
    source
  with
  | Pyre.ParserError _
  | Generator.Error ->
      let location =
        Location.create
          ~start:buffer.Lexing.lex_curr_p
          ~stop:buffer.Lexing.lex_curr_p
      in
      let line = location.Location.start.Location.line - 1
      and column = location.Location.start.Location.column in

      let header =
        Format.asprintf
          "\nCould not parse test at %a"
          Location.Reference.pp location
      in
      let indicator =
        if column > 0 then (String.make (column - 1) ' ') ^ "^" else "^" in
      let error =
        match List.nth (String.split source ~on:'\n') line with
        | Some line -> Format.asprintf "%s:\n  %s\n  %s" header line indicator
        | None -> header ^ "." in
      if not silent then
        Printf.printf "%s" error;
      failwith "Could not parse test"


let parse
    ?(handle = "test.py")
    ?(qualifier = [])
    ?(debug = true)
    ?(version = 3)
    ?(docstring = None)
    ?local_mode
    source =
  Ast.SharedMemory.Handles.add_handle_hash ~handle;
  let ({ Source.metadata; _ } as source) =
    trim_extra_indentation source
    |> parse_untrimmed ~handle ~qualifier ~debug ~version ~docstring
  in
  match local_mode with
  | Some local_mode ->
      { source with Source.metadata = { metadata with Source.Metadata.local_mode } }
  | _ ->
      source


let parse_list named_sources =
  let create_file (name, source) =
    File.create
      ~content:(trim_extra_indentation source)
      (Path.create_relative ~root:(Path.current_working_directory ()) ~relative:name)
  in
  Service.Parser.parse_sources
    ~configuration:(
      Configuration.Analysis.create ~local_root:(Path.current_working_directory ()) ())
    ~scheduler:(Scheduler.mock ())
    ~files:(List.map ~f:create_file named_sources)


let parse_single_statement source =
  match parse source with
  | { Source.statements = [statement]; _ } -> statement
  | _ -> failwith "Could not parse single statement"


let parse_last_statement source =
  match parse source with
  | { Source.statements; _ } when List.length statements > 0 ->
      List.last_exn statements
  | _ -> failwith "Could not parse last statement"


let parse_single_assign source =
  match parse_single_statement source with
  | { Node.value = Statement.Assign assign; _ } -> assign
  | _ -> failwith "Could not parse single assign"


let parse_single_define source =
  match parse_single_statement source with
  | { Node.value = Statement.Define define; _ } -> define
  | _ -> failwith "Could not parse single define"


let parse_single_class source =
  match parse_single_statement source with
  | { Node.value = Statement.Class definition; _ } -> definition
  | _ -> failwith "Could not parse single class"


let parse_single_expression source =
  match parse_single_statement source with
  | { Node.value = Statement.Expression expression; _ } -> expression
  | _ -> failwith "Could not parse single expression."


let parse_single_access source =
  match parse_single_expression source with
  | { Node.value = Expression.Access access; _ } -> access
  | _ -> failwith "Could not parse single access"


let parse_callable callable =
  parse_single_expression callable
  |> Type.create ~aliases:(fun _ -> None)


let diff ~print format (left, right) =
  let escape string =
    String.substr_replace_all string ~pattern:"\"" ~with_:"\\\""
    |> String.substr_replace_all ~pattern:"'" ~with_:"\\\""
    |> String.substr_replace_all ~pattern:"`" ~with_:"?"
    |> String.substr_replace_all ~pattern:"$" ~with_:"?"
  in
  let input =
    Format.sprintf
      "bash -c \"diff -u <(echo '%s') <(echo '%s')\""
      (escape (Format.asprintf "%a" print left))
      (escape (Format.asprintf "%a" print right))
    |> Unix.open_process_in in
  Format.fprintf format "\n%s" (In_channel.input_all input);
  In_channel.close input


let assert_source_equal =
  assert_equal
    ~cmp:Source.equal
    ~printer:(fun source -> Format.asprintf "%a" Source.pp source)
    ~pp_diff:(diff ~print:Source.pp)


let add_defaults_to_environment environment_handler =
  let source =
    parse {|
      class unittest.mock.Base: ...
      class unittest.mock.Mock(unittest.mock.Base): ...
      class unittest.mock.NonCallableMock: ...
    |};
  in
  Service.Environment.populate environment_handler [source]


(* Expression helpers. *)
let (~+) value =
  Node.create_with_default_location value


let (~~) =
  Identifier.create


let (!) name =
  let open Expression in
  +Access (Access.create name)


let (!!) name =
  +Statement.Expression !name


(* Assertion helpers. *)
let assert_true =
  assert_bool ""


let assert_false test =
  assert_bool "" (not test)


let assert_is_some test =
  assert_true (Option.is_some test)


let assert_is_none test =
  assert_true (Option.is_none test)


let assert_unreached () =
  assert_true false


let mock_path path =
  Path.create_relative ~root:(Path.current_working_directory ()) ~relative:path


let write_file (path, content) =
  let content = trim_extra_indentation content in
  let file = File.create ~content (mock_path path) in
  File.write file;
  file


(* Override `OUnit`s functions the return absolute paths. *)
let bracket_tmpdir ?suffix context =
  bracket_tmpdir ?suffix context
  |> Filename.realpath


let bracket_tmpfile ?suffix context =
  bracket_tmpfile ?suffix context
  |> (fun (filename, channel) -> Filename.realpath filename, channel)


(* Common type checking and analysis setup functions. *)
let mock_configuration =
  Configuration.Analysis.create ()


let typeshed_stubs = (* Yo dawg... *)
  [
    Source.create ~qualifier:(Access.create "sys") [];
    parse
      ~qualifier:(Access.create "hashlib")
      ~handle:"hashlib.pyi"
      {|
        _DataType = typing.Union[int, str]
        class _Hash:
          digest_size: int
        def md5(input: _DataType) -> _Hash: ...
      |}
    |> Preprocessing.qualify;
    parse
      ~qualifier:(Access.create "typing")
      ~handle:"typing.pyi"
      {|
        class _SpecialForm: ...
        class TypeAlias: ...

        TypeVar = object()
        List = TypeAlias(object)
        Dict = TypeAlias(object)
        Type: _SpecialForm = ...

        class Sized: ...

        _T = TypeVar('_T')
        _S = TypeVar('_S')
        _KT = TypeVar('_KT')
        _VT = TypeVar('_VT')
        _T_co = TypeVar('_T_co', covariant=True)
        _V_co = TypeVar('_V_co', covariant=True)
        _KT_co = TypeVar('_KT_co', covariant=True)
        _VT_co = TypeVar('_VT_co', covariant=True)
        _T_contra = TypeVar('_T_contra', contravariant=True)

        class Generic(): pass

        class Iterable(Protocol[_T_co]):
          def __iter__(self) -> Iterator[_T_co]: pass
        class Iterator(Iterable[_T_co], Protocol[_T_co]):
          def __next__(self) -> _T_co: ...

        class AsyncIterable(Protocol[_T_co]):
          def __aiter__(self) -> AsyncIterator[_T_co]: ...
        class AsyncIterator(AsyncIterable[_T_co],
                    Protocol[_T_co]):
          def __anext__(self) -> Awaitable[_T_co]: ...
          def __aiter__(self) -> AsyncIterator[_T_co]: ...

        if sys.version_info >= (3, 6):
          class Collection(Iterable[_T_co]): ...
          _Collection = Collection
        else:
          class _Collection(Iterable[_T_co]): ...
        class Sequence(_Collection[_T_co], Generic[_T_co]): pass

        class Generator(Generic[_T_co, _T_contra, _V_co], Iterator[_T_co]):
          pass
        class Mapping(_Collection[_KT], Generic[_KT, _VT_co]):
          pass

        class Awaitable(Protocol[_T_co]): pass
        class AsyncGenerator(Generic[_T_co, _T_contra]):
          def __aiter__(self) -> 'AsyncGenerator[_T_co, _T_contra]': ...
          def __anext__(self) -> Awaitable[_T_co]: ...

        def cast(tp: Type[_T], o: Any) -> _T: ...
      |}
    |> Preprocessing.qualify;
    Source.create ~qualifier:(Access.create "unittest.mock") [];
    parse
      ~qualifier:[]
      ~handle:"builtins.pyi"
      {|
        import typing

        _T = typing.TypeVar('_T')
        _T_co = typing.TypeVar('_T_co')
        _S = typing.TypeVar('_S')


        def not_annotated(input = ...): ...

        class type:
          __name__: str = ...
        class object():
          def __init__(self) -> None: pass
          def __new__(self) -> typing.Any: pass
          def __sizeof__(self) -> int: pass

        class ellipses: ...

        class slice:
          @overload
          def __init__(self, stop: typing.Optional[int]) -> None: ...
          @overload
          def __init__(
            self,
            start: typing.Optional[int],
            stop: typing.Optional[int],
            step: typing.Optional[int] = ...
          ) -> None: ...
          def indices(self, len: int) -> Tuple[int, int, int]: ...

        class range(typing.Sequence[int]):
          @overload
          def __init__(self, stop: int) -> None: ...

        class super:
           @overload
           def __init__(self, t: typing.Any, obj: typing.Any) -> None: ...
           @overload
           def __init__(self, t: typing.Any) -> None: ...
           @overload
           def __init__(self) -> None: ...

        class bool(): ...

        class bytes(): ...

        class float():
          def __add__(self, other) -> float: ...
          def __radd__(self, other: float) -> float: ...
          def __neg__(self) -> float: ...
          def __abs__(self) -> float: ...

        class int(float):
          def __init__(self, value) -> None: ...
          def __le__(self, other) -> bool: ...
          def __lt__(self, other) -> bool: ...
          def __ge__(self, other) -> bool: ...
          def __gt__(self, other) -> bool: ...
          def __eq__(self, other) -> bool: ...
          def __ne__(self, other) -> bool: ...
          def __add__(self, other: int) -> int: ...
          def __mod__(self, other) -> int: ...
          def __radd__(self, other: int) -> int: ...
          def __neg__(self) -> int: ...
          def __pos__(self) -> int: ...
          def __str__(self) -> bool: ...
          def __invert__(self) -> int: ...

        class complex():
          def __radd__(self, other: int) -> int: ...

        class str(typing.Sized, typing.Sequence[str]):
          @overload
          def __init__(self, o: object = ...) -> None: ...
          @overload
          def __init__(self, o: bytes, encoding: str = ..., errors: str = ...) -> None: ...
          def lower(self) -> str: pass
          def upper(self) -> str: ...
          def substr(self, index: int) -> str: pass
          def __lt__(self, other) -> float: ...
          def __ne__(self, other) -> int: ...
          def __add__(self, other: str) -> str: ...
          def __pos__(self) -> float: ...
          def __repr__(self) -> float: ...
          def __str__(self) -> str: ...
          def __getitem__(self, i: typing.Union[int, slice]) -> str: ...
          def __iter__(self) -> typing.Iterator[str]: ...

        class tuple(typing.Sequence[_T], typing.Sized, typing.Generic[_T]):
          def __init__(self, a: typing.List[_T]): ...
          def tuple_method(self, a: int): ...

        class dict(typing.Generic[_T, _S], typing.Iterable[_T]):
          def add_key(self, key: _T) -> None: pass
          def add_value(self, value: _S) -> None: pass
          def add_both(self, key: _T, value: _S) -> None: pass
          def items(self) -> typing.Iterable[typing.Tuple[_T, _S]]: pass
          def __getitem__(self, k: _T) -> _S: ...
          @overload
          def get(self, k: _T) -> typing.Optional[_S]: ...
          @overload
          def get(self, k: _T, default: _S) -> _S: ...
          @overload
          def update(self, __m: typing.Dict[_T, int], **kwargs: _S): ...
          @overload
          def update(self, **kwargs: _S): ...

        class list(typing.Sequence[_T], typing.Generic[_T]):
          @overload
          def __init__(self) -> None: ...
          @overload
          def __init__(self, iterable: typing.Iterable[_T]) -> None: ...

          def __add__(self, x: list[_T]) -> list[_T]: ...
          def __iter__(self) -> typing.Iterator[_T]: ...
          def append(self, element: _T) -> None: ...
          @overload
          def __getitem__(self, i: int) -> _T: ...
          @overload
          def __getitem__(self, s: slice) -> typing.List[_T]: ...
          def __contains__(self, o: object) -> bool: ...

        class set(typing.Iterable[_T], typing.Generic[_T]): pass

        def len(o: typing.Sized) -> int: ...
        def isinstance(
          a: object,
          b: typing.Union[type, typing.Tuple[typing.Union[type, typing.Tuple], ...]]
        ) -> bool: ...
        def sum(iterable: typing.Iterable[_T]) -> typing.Union[_T, int]: ...

        class IsAwaitable(typing.Awaitable[int]): pass
        class contextlib.ContextManager(typing.Generic[_T_co]):
          def __enter__(self) -> _T_co:
            pass
        class contextlib.GeneratorContextManager(
            contextlib.ContextManager[_T],
            typing.Generic[_T]):
          pass
        def sys.exit(code: int) -> typing.NoReturn: ...

        def eval(source: str) -> None: ...

        def to_int(x: typing.Any) -> int: ...
        def int_to_str(i: int) -> str: ...
        def str_to_int(i: str) -> int: ...
        def optional_str_to_int(i: typing.Optional[str]) -> int: ...
        def int_to_bool(i: int) -> bool: ...
        def int_to_int(i: int) -> int: pass
        def str_float_to_int(i: str, f: float) -> int: ...
        def str_float_tuple_to_int(t: typing.Tuple[str, float]) -> int: ...
        def nested_tuple_to_int(t: typing.Tuple[typing.Tuple[str, float], float]) -> int: ...
        def return_tuple() -> typing.Tuple[int, int]: ...
        def unknown_to_int(i) -> int: ...
        def star_int_to_int( *args, x: int) -> int: ...
        def takes_iterable(x: typing.Iterable[_T]) -> None: ...
        def awaitable_int() -> typing.Awaitable[int]: ...
        def condition() -> bool: ...

        class A: ...
        class B(A): ...
        class C(A): ...
        class D(B,C): ...
        class obj():
          @staticmethod
          def static_int_to_str(i: int) -> str: ...

        def identity(x: _T) -> _T: ...
        _VR = typing.TypeVar("_VR", str, int)
        def variable_restricted_identity(x: _VR) -> _VR: pass

        def returns_undefined()->Undefined: ...
        class Spooky:
          def undefined(self)->Undefined: ...

        class Attributes:
          int_attribute: int

        class OtherAttributes:
          int_attribute: int
          str_attribute: str
      |}
    |> Preprocessing.qualify;
    parse
      ~qualifier:(Access.create "django.http")
      ~handle:"django/http.pyi"
      {|
        class Request:
          GET: typing.Dict[str, typing.Any] = ...
          POST: typing.Dict[str, typing.Any] = ...
      |}
    |> Preprocessing.qualify;
    parse
      ~qualifier:(Access.create "os")
      ~handle:"os.pyi"
      {|
        environ: Dict[str, str] = ...
      |}
    |> Preprocessing.qualify;
    parse
      ~qualifier:(Access.create "subprocess")
      ~handle:"subprocess.pyi"
      {|
        def run(command, shell): ...
        def call(command, shell): ...
        def check_call(command, shell): ...
        def check_output(command, shell): ...
      |}
    |> Preprocessing.qualify;
  ]


let environment ?(sources = typeshed_stubs) ?(configuration = mock_configuration) () =
  let environment = Environment.Builder.create () in
  Service.Environment.populate (Environment.handler ~configuration environment) sources;
  Environment.handler ~configuration environment


let mock_define = {
  Define.name = Access.create "$empty";
  parameters = [];
  body = [];
  decorators = [];
  docstring = None;
  return_annotation = None;
  async = false;
  generated = false;
  parent = None;
}


let resolution ?(sources = typeshed_stubs) () =
  let environment = environment ~sources () in
  add_defaults_to_environment environment;
  TypeCheck.resolution environment ()


type test_update_environment_with_t = {
  qualifier: Access.t;
  handle: string;
  source: string;
}
[@@deriving compare, eq, show]


let assert_errors
    ?(autogenerated = false)
    ?(debug = true)
    ?(strict = false)
    ?(declare = false)
    ?(infer = false)
    ?(show_error_traces = false)
    ?(qualifier = [])
    ?(handle = "test.py")
    ?(update_environment_with = [])
    ~check
    source
    errors =
  Annotated.Class.Attribute.Cache.clear ();
  let descriptions =
    let mode_override =
      if infer then
        Some Source.Infer
      else if strict then
        Some Source.Strict
      else if declare then
        Some Source.Declare
      else if debug then
        None
      else
        Some Source.Default
    in
    let check ?mode_override source =
      let parse ~qualifier ~handle ~source =
        let metadata =
          Source.Metadata.create
            ~autogenerated
            ~debug
            ~declare
            ~ignore_lines:[]
            ~strict
            ~version:3
            ~number_of_lines:(-1)
            ()
        in
        parse ~handle ~qualifier source
        |> (fun source -> { source with Source.metadata })
        |> Preprocessing.preprocess
        |> Plugin.apply_to_ast
      in
      let source = parse ~qualifier ~handle ~source in
      let environment =
        let sources =
          source
          :: List.map
            update_environment_with
            ~f:(fun { qualifier; handle; source } -> parse ~qualifier ~handle ~source)
        in
        let environment = environment ~configuration:mock_configuration () in
        Service.Environment.populate environment sources;
        environment
      in
      let configuration =
        Configuration.Analysis.create ~debug ~strict ~declare ~infer ()
      in
      check ~configuration ~environment ?mode_override ~source
    in
    List.map
      (check ?mode_override source)
      ~f:(fun error -> Error.description error ~detailed:show_error_traces)
  in
  assert_equal
    ~cmp:(List.equal ~equal:String.equal)
    ~printer:(String.concat ~sep:"\n")
    errors
    descriptions

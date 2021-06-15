include Btree_intf

let ( // ) a b = a ^ "/" ^ b

module Make (InKey : Input.Key) (InValue : Input.Value) (Size : Input.Size) :
  S with type key = InKey.t and type value = InValue.t = struct
  type key = InKey.t

  type value = InValue.t

  module Params = Params.Make (Size) (InKey) (InValue)
  module Common = Field.MakeCommon (Params)
  module Entry = Data.Make (InKey) (InValue)
  module Key = Entry.Key
  module Value = Entry.Value
  module Store = Store.Make (Params) (Common)
  module Page = Store.Page
  module Leaf = Leaf.Make (Params) (Store) (Key) (Value)
  module Node = Node.Make (Params) (Store) (Key)

  open Stats.Func
  (** STAT WRAPPERS **)

  open Stats.Btree

  let () = if Params.debug then Log.warn (fun reporter -> reporter "Debug mode is set.")

  let min_key = Key.min

  type t = { store : Store.t; mutable instances : int }

  type cache = (string, t) Hashtbl.t

  let caches = ref []

  let empty_cache () : cache =
    let cache = Hashtbl.create 10 in
    caches := cache :: !caches;
    cache

  let flush t = Store.flush t.store

  let clear t =
    Log.debug (fun reporter -> reporter "clearing");
    Store.clear t.store;
    Leaf.init t.store (Store.root t.store) |> ignore;
    flush t

  let close t =
    Log.debug (fun reporter ->
        reporter "Closing a btree instance at root %s" (Store.Private.dir t.store));
    t.instances <- t.instances - 1;
    if t.instances = 0 then (
      Log.info (fun reporter -> reporter "Closing %s/b.tree" (Store.Private.dir t.store));
      Store.close t.store;
      List.iter (fun cache -> Hashtbl.remove cache (Store.Private.dir t.store)) !caches)

  let snapshot ?(depth = 0) t =
    (* for every node/leaf in [t] which are at least [depth] away from the leaves, [snapshot ~depth t], write in a file its rep as given by their corresponding pp function *)
    let snap_page address page =
      let kind = Page.kind page in
      if Common.Kind.to_depth kind >= depth then
        match Common.Kind.from_t kind with
        | Leaf ->
            let leaf = Leaf.load t.store address in
            let out_file =
              open_out ((Store.Private.dir t.store // "pp_page_") ^ string_of_int address ^ ".ansi")
            in
            let formatter = out_file |> Format.formatter_of_out_channel in
            Fmt.set_style_renderer formatter `Ansi_tty;
            Fmt.pf formatter "%a@." Leaf.pp leaf;
            close_out out_file;
            Store.release_ro t.store
        | Node _n ->
            let node = Node.load t.store address in
            let out_file =
              open_out ((Store.Private.dir t.store // "pp_page_") ^ string_of_int address ^ ".ansi")
            in
            let formatter = out_file |> Format.formatter_of_out_channel in
            Fmt.set_style_renderer formatter `Ansi_tty;
            Fmt.pf formatter "%a@." (Node.pp |> Fmt.vbox) node;
            close_out out_file
    in
    flush t;
    Store.iter t.store snap_page;
    let out_header = open_out (Store.Private.dir t.store // "pp_header.ansi") in
    let formatter = out_header |> Format.formatter_of_out_channel in
    Fmt.set_style_renderer formatter `Ansi_tty;
    Fmt.pf formatter "%a@." Store.pp_header t.store;
    close_out out_header

  let length tree =
    let rec aux address =
      let page = Store.load tree.store address in
      match Page.kind page |> Common.Kind.from_t with
      | Leaf ->
          let leaf = Leaf.load tree.store address in
          let ret = Leaf.length leaf in
          Store.release_ro tree.store;
          ret
      | Node _depth ->
          let node = Node.load tree.store address in
          Node.fold_left (fun acc _key address -> acc + aux address) 0 node
    in
    let root = Store.root tree.store in
    aux root

  let create ?cache root =
    Log.info (fun reporter -> reporter "Btree version %i (13 Apr. 2021)" Size.version);
    Log.debug (fun reporter -> reporter "Btree at root %s" root);
    let cache = match cache with None -> empty_cache () | Some cache -> cache in
    if Hashtbl.mem cache root then (
      let t = Hashtbl.find cache root in
      t.instances <- t.instances + 1;
      t)
    else
      let just_load = Sys.file_exists (root ^ "/" ^ "b.tree") in
      let t = { store = Store.init ~root; instances = 1 } in
      if just_load then Log.debug (fun reporter -> length t |> reporter "Loading %i bindings")
      else (
        Leaf.init t.store (Store.root t.store) |> ignore;
        flush t);
      Hashtbl.add cache root t;
      t

  let rec go_to_leaf tree key address =
    let page = Store.load tree.store address in
    match Page.kind page |> Common.Kind.from_t with
    | Leaf -> address
    | Node _depth ->
        let node = Node.load tree.store address in
        go_to_leaf tree key (Node.find node key)

  let find tree inkey =
    tic stat_find;
    let key = Key.of_input inkey in
    let go_to_leaf = go_to_leaf tree key in
    let address = go_to_leaf (Store.root tree.store) in
    let leaf = Leaf.load tree.store address in
    let ret = Leaf.find leaf key |> Value.to_input in
    Store.release_ro tree.store;
    tac stat_find;
    ret

  let mem tree inkey =
    tic stat_mem;
    let key = Key.of_input inkey in
    let go_to_leaf = go_to_leaf tree key in
    let address = go_to_leaf (Store.root tree.store) in
    let leaf = Leaf.load tree.store address in
    let ret = Leaf.mem leaf key in
    Store.release_ro tree.store;
    tac stat_mem;
    ret

  let path_to_leaf t key =
    let rec aux path address =
      let page = Store.load t.store address in
      match Page.kind page |> Common.Kind.from_t with
      | Leaf -> address :: path
      | Node _depth ->
          let node = Node.load t.store address in
          aux (address :: path) (Node.find node key)
    in

    aux [] (Store.root t.store)

  let path_to_leaf_with_neighbour t key =
    let rec aux path_with_neighbour address =
      let page = Store.load t.store address in
      match Page.kind page |> Common.Kind.from_t with
      | Leaf -> (address, path_with_neighbour)
      | Node _depth ->
          let node = Node.load t.store address in
          let neighbour = Node.find_with_neighbour node key in
          let next = neighbour.main |> snd in
          aux ((address, neighbour) :: path_with_neighbour) next
    in
    aux [] (Store.root t.store)

  let add tree inkey invalue =
    tic stat_add;
    Index_stats.incr_nb_replace ();
    let key = Key.of_input inkey in
    let value = Value.of_input invalue in
    let path = path_to_leaf tree key in
    let leaf_address = List.hd path in

    let rec split_nodes nodes promoted allocated_address =
      match nodes with
      | [] ->
          (* this case happens only when no nodes are there in the first place *and* the leaf has overflowed
             This means that the tree is a single leaf, and we have to create a new root on top of it *)
          let root = Node.create tree.store Common.Kind.(of_depth 1 |> from_t) in
          Node.add root min_key leaf_address;
          Node.add root promoted allocated_address;
          Store.reroot tree.store (Node.self_address root);
          Log.info (fun reporter -> reporter "Btree height increases to 1")
      | [ address ] ->
          (* there are no nodes above : we are at the root *)
          let root = Node.load tree.store address in
          Node.add root promoted allocated_address;
          if Node.overflow root then (
            let promoted, allocated = Node.split root in
            let new_root =
              Node.create tree.store Common.Kind.(of_depth (1 + Node.depth root) |> from_t)
            in
            Node.add new_root min_key address;
            Node.add new_root promoted (Node.self_address allocated);
            Store.reroot tree.store (Node.self_address new_root);
            Log.info (fun reporter -> reporter "Btree height increases to %i" (Node.depth new_root)))
      | address :: nodes ->
          let node = Node.load tree.store address in
          Node.add node promoted allocated_address;
          if Node.overflow node then
            let promoted, allocated = Node.split node in
            split_nodes nodes promoted (Node.self_address allocated)
    in

    let leaf = Leaf.load tree.store leaf_address in
    Leaf.add leaf key value;
    (if Leaf.overflow leaf then
     let promoted, allocated = Leaf.split leaf in
     split_nodes (List.tl path) promoted (Leaf.self_address allocated));
    Store.release tree.store;
    tac stat_add

  module type MERGER = sig
    type t

    val load : Store.t -> Store.address -> t

    val leftmost : t -> Key.t

    val merge : t -> t -> [ `Partial | `Total ]
  end

  let choose_kind t address =
    match Store.load t.store address |> Page.kind |> Common.Kind.from_t with
    | Leaf -> (module Leaf : MERGER)
    | Node _ -> (module Node)

  let remove t inkey =
    let rec merges path =
      match path with
      | [] -> ()
      | (address, ({ main; neighbour; order } : Node.neighbour)) :: path -> (
          match neighbour with
          | None ->
              if not (path = []) then failwith "No neighbour";
              (* we are at the root, which contains only a single key and acts as a mere redirection. We want to remove it and make its only child the new root*)
              Store.reroot t.store (snd main);
              Log.info (fun reporter ->
                  reporter "Btree height decreases to %i"
                    (Store.load t.store (snd main) |> Page.kind |> Common.Kind.to_depth))
          | Some neighbour ->
              let node = Node.load t.store address in
              let k1, address1 = main in
              let k2, address2 = neighbour in
              let module Merger = (val choose_kind t address1) in
              let v1, v2 = Merger.(load t.store address1, load t.store address2) in
              (match order with
              | `Lower -> (
                  match Merger.merge v2 v1 with
                  | `Partial ->
                      Fmt.pr "Replacing %a with %a@." Key.pp k1 Key.pp (Merger.leftmost v1);
                      Node.replace node k1 (Merger.leftmost v1)
                  | `Total ->
                      Fmt.pr "key : %a@." Key.pp k1;
                      Node.remove node k1)
              | `Higher -> (
                  match Merger.merge v1 v2 with
                  | `Partial ->
                      Fmt.pr "Replacing %a with %a@." Key.pp k2 Key.pp (Merger.leftmost v2);
                      Node.replace node k2 (Merger.leftmost v2)
                  | `Total -> Node.remove node k2));
              if Node.underflow node then merges path)
    in
    let key = Key.of_input inkey in
    let leaf_address, path = path_to_leaf_with_neighbour t key in
    let leaf = Leaf.load t.store leaf_address in
    Leaf.remove leaf key;
    if Leaf.underflow leaf then merges path;
    Store.release t.store

  let iter func tree =
    let func key value = func (key |> Key.to_input) (value |> Value.to_input) in
    let rec aux address =
      let page = Store.load tree.store address in
      match Page.kind page |> Common.Kind.from_t with
      | Leaf ->
          let leaf = Leaf.load tree.store address in
          Leaf.iter leaf func;
          Store.release_ro tree.store
      | Node _depth ->
          let node = Node.load tree.store address in
          Node.iter node (fun _key address -> aux address)
    in
    let root = Store.root tree.store in
    aux root

  let iteri func tree =
    let counter = ref 0 in
    let f key value =
      incr counter;
      func !counter key value
    in
    iter f tree

  let depth_of n =
    let rec aux h n = if n = 0 then h else aux (h + 1) (n / Params.fanout) in
    aux (-1) n

  let init ~root n ~read =
    Log.info (fun reporter -> reporter "Btree version %i (13 Apr. 2021)" Size.version);
    let store = Store.init ~root in
    Log.info (fun reporter -> reporter "Initialising btree with %i bindings" n);

    let rec nvertices depth =
      match depth with
      | 0 -> 1
      | 1 -> Params.fanout
      | n -> (
          let sqrt = nvertices (depth / 2) in
          let sqrt2 = sqrt * sqrt in
          match n mod 2 with 0 -> sqrt2 | _ -> Params.fanout * sqrt2)
    in

    let sequentiate n depth =
      let step = nvertices depth in
      let steps = List.init (n / step) (fun _ -> step) in
      match n mod step with 0 -> steps | m -> steps @ [ m ]
    in

    let add content = Store.Private.write store content in

    let depth = depth_of n in

    let address = ref (Store.root store - 1) in
    Store.Private.init_migration store;

    let get_address () =
      let open Common.Address in
      let buff = Bytes.create size in
      !address |> to_t |> set buff ~off:0;
      Bytes.to_string buff
    in
    let rec create leftmost depth n =
      match depth with
      | 0 ->
          incr address;
          let kvs = List.init n (fun _ -> read 1) in
          let k_dump = String.sub (List.hd kvs) 0 Params.key_sz in
          let content = Leaf.migrate kvs in
          let pad = Params.page_sz - String.length content in
          if pad < 0 then (
            Fmt.pr "Assertion error : [page size] must be at least %i@." (String.length content);
            assert false);
          add (content ^ String.make pad '\000');
          k_dump
      | _ ->
          let ns = sequentiate n depth in
          assert (n = List.fold_left ( + ) 0 ns);
          let kvs =
            List.mapi
              (fun i n ->
                let k_dump = create (leftmost && i = 0) (depth - 1) n in
                let address_dump = get_address () in
                (if leftmost && i = 0 then min_key |> Key.debug_dump else k_dump) ^ address_dump)
              ns
          in
          let content = Node.migrate kvs Common.Kind.(of_depth depth |> from_t) in
          let pad = Params.page_sz - String.length content in
          incr address;
          add (content ^ String.make pad '\000');
          String.sub (List.hd kvs) 0 Params.key_sz
    in

    create true depth n |> ignore;
    Store.Private.end_migration store (!address + 1) !address;
    incr address;
    { store; instances = 1 }

  let pp ppf t =
    Fmt.pf ppf "@[<hov 2>ROOT OF THE TREE:@;%a@]" Leaf.pp (Leaf.load t.store (Store.root t.store))

  module Private = struct
    let dir tree = Store.Private.dir tree.store

    let root tree = Store.root tree.store

    let store tree = tree.store

    let pp t ppf address =
      let page = Store.load t.store address in
      match Page.kind page |> Common.Kind.from_t with
      | Leaf ->
          let leaf = Leaf.load t.store address in
          Fmt.set_style_renderer ppf `Ansi_tty;
          Fmt.pf ppf "%a@." Leaf.pp leaf
      | Node _n ->
          let node = Node.load t.store address in
          Fmt.set_style_renderer ppf `Ansi_tty;
          Fmt.pf ppf "%a@." (Node.pp |> Fmt.vbox) node

    let go_to_leaf tree inkey =
      let key = Key.of_input inkey in
      let rec aux tree key address acc =
        let page = Store.load tree.store address in
        match Page.kind page |> Common.Kind.from_t with
        | Leaf -> address :: acc
        | Node _depth ->
            let node = Node.load tree.store address in
            aux tree key (Node.find node key) (address :: acc)
      in
      aux tree key (Store.root tree.store) []

    module Params = Params
    module Common = Common
    module Entry = Entry
    module Key = Key
    module Value = Value
    module Store = Store
    module Page = Page
    module Leaf = Leaf
    module Node = Node
  end
end

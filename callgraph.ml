(*pp deriving *)
(* Facilities for determining and restructuring static call graphs *)

open Utility
open List
open Syntax


(** {1 Callgraph ordering}

    Find the cliques in a group of functions.  Whenever there's mutual
    recursion we need to type all the functions in the cycle as
    `letrec-bound'; we want to avoid doing this in all other cases to
    make everything as polymorphic as possible (and to make typing
    faster).  In such cases the bindings must be reordered so that we
    type called functions before their callers.

    The plan is as follows:
    1. Find the call graph (by analysing the rhs for free variables.)
    2. Find all the cycles (strongly-connected components) in the call graph.
    3. Collapse cycles to single nodes and perform a topological sort
       to obtain the ordering.
*)

let is_mapped_by alist x = mem_assoc x alist

(** [make_callgraph bindings] returns an alist that gives a list of called
    functions for each function in [bindings] *)
let make_callgraph bindings = 
  alistmap
    (fun expr -> 
       filter (is_mapped_by bindings) (freevars expr)) 
    bindings

let group_and_order_bindings_by_callgraph 
    (bindings : (string * 'a expression') list) 
    : string list list = 
  let call_graph = make_callgraph bindings in
    Graph.topo_sort_cliques call_graph

let defs_to_bindings l = 
  map (fun (Define (name, body, _, _)) -> name, body) l

let rec defn_of symbol = function
  | Define(n, _, _, _) as expr :: _ when n = symbol -> expr
  | _ :: defns -> defn_of symbol defns

let find_defn_in x y = defn_of y x

(** order_exprs_by_callgraph takes a list of groupings of functions
    and returns a new, possibly finer, list of groupings of functions.
    Each of the new groupings should truly be mutually recursive and
    the groupings should be ordered in callgraph-order (but note that
    bindings are only determined within the original groupings; how
    does this work with redefined function names that are part of
    mut-rec call groups? )*)
let refine_def_groups (expr_lists : 'a expression' list list) : 'a expression' list list = 
  let regroup_defs defs = 
    let bindings = defs_to_bindings defs in
    let cliques = group_and_order_bindings_by_callgraph bindings in
      map (map (find_defn_in defs)) cliques 
  in
    (* Each grouping in the input will be broken down into a new list
       of groupings. We only care about the new groupings, so we
       concat_map to bring them together *)
    concat_map (function
                  | Define _ :: _ as defs -> regroup_defs defs
                  | e                     -> [e]) expr_lists
      

(** Removes defs from [env] that aren't used by [expr]. *)
module DeadCode =
struct
  type clique = {
    free_names : string list;
    exposed_names : string list;
    defs : expression list
  }

  let elim_dead_defs globals env expr =
    let filter_globals = filter (fun name -> not (mem name globals)) in
    let defs, other = either_partition  (function Define _ as d -> Left d | e -> Right e) env in
    let groupings = refine_def_groups [defs] in
    let clique_info = map (fun exprs ->
                             {free_names = filter_globals (concat_map freevars exprs);
                              exposed_names = map fst (defs_to_bindings exprs);
                              defs = exprs}) groupings 
    and expr_info = { free_names =  filter_globals (freevars expr);
                      exposed_names = [];
                      defs = [] } in

    let rec close env = 
        match env.free_names with 
          | [] -> env
          | names -> 
              let defines name {exposed_names = names} = List.mem name names in
              let defining_cliques =  List.map (fun name -> List.find (defines name) clique_info) names in
                close (List.fold_right (fun clique env ->
                                          let exposed_names = env.exposed_names @ clique.exposed_names in
                                            { free_names = List.filter (fun name -> not (List.mem name exposed_names)) 
                                                (env.free_names @ clique.free_names);
                                              exposed_names = exposed_names;
                                              defs = clique.defs @ env.defs}) defining_cliques env)
    in
      other @ (close expr_info).defs @ [expr]

end

let elim_dead_defs = DeadCode.elim_dead_defs
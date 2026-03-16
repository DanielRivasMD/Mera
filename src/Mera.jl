####################################################################################################

module Mera

####################################################################################################

using TOML
using YAML

####################################################################################################

export Mera, load, set_base!, set_default!, load_default!, path, ensure, mirror

####################################################################################################
# Data structures
####################################################################################################

"""
    RelTree

A node in the relative directory tree.
- `relpath::String`: path of this node relative to its root.
- `children::Dict{String,RelTree}`: subdirectories.
"""
struct RelTree
  relpath::String
  children::Dict{String,RelTree}
end

"""
    Mera

Main type holding the project's directory definitions.
- `roots::Dict{Symbol,RelTree}`: mapping from root name to relative tree.
- `bases::Dict{Symbol,String}`: mapping from root name to absolute base path.
- `config_path::String`: path to the configuration file used.
"""
struct Mera
  roots::Dict{Symbol,RelTree}
  bases::Dict{Symbol,String}
  config_path::String
end

"""
    PathNode

A helper type to enable dot‑syntax navigation of the directory tree.
It stores a reference to the parent `Mera`, the root name, and the
list of segments traversed so far.
"""
struct PathNode
  mera::Mera
  root::Symbol
  segments::Vector{String}
end

####################################################################################################
# Internal tree building
####################################################################################################

function _build_tree(node::Dict, parent_relpath::String)::RelTree
  children = Dict{String,RelTree}()
  if haskey(node, "children")
    child_names = node["children"]
    for name in child_names
      # If the child has its own subsection, use it; otherwise treat as empty
      child_node = get(node, name, Dict{String,Any}())
      child_relpath = joinpath(parent_relpath, name)
      children[name] = _build_tree(child_node, child_relpath)
    end
  end
  return RelTree(parent_relpath, children)
end

####################################################################################################
# Public API
####################################################################################################

"""
    load(config_file::String; bases::Dict{Symbol,String}=Dict{Symbol,String}()) -> Mera

Parse a TOML or YAML configuration file and return a `Mera` instance.
The file must contain top‑level tables, each representing a root directory.
Each table may have a `"children"` list and corresponding subtables.

Optionally provide a dictionary of base paths for some or all roots.
Use `set_base!` later to add or change base paths.
"""
function load(config_file::String; bases::Dict{Symbol,String} = Dict{Symbol,String}())
  ext = splitext(config_file)[2]
  data = if ext in (".toml",)
    TOML.parsefile(config_file)
  elseif ext in (".yaml", ".yml")
    YAML.load_file(config_file)
  else
    throw(ArgumentError("Unsupported file extension: $ext. Use .toml, .yaml, or .yml"))
  end

  roots = Dict{Symbol,RelTree}()
  for (root_name, root_config) in data
    root_sym = Symbol(root_name)
    roots[root_sym] = _build_tree(root_config, "")
  end

  # Warn about bases given for unknown roots
  for (root, _) in bases
    if !haskey(roots, root)
      @warn "Base provided for unknown root: $root"
    end
  end

  return Mera(roots, bases, config_file)
end

"""
    set_base!(mera::Mera, root::Symbol, base::String)

Set or change the absolute base path for a given root.
"""
function set_base!(mera::Mera, root::Symbol, base::String)
  mera.bases[root] = base
  return mera
end

####################################################################################################
# Dot syntax support
####################################################################################################

function Base.getproperty(m::Mera, name::Symbol)
  # Access roots field without triggering getproperty again
  roots = getfield(m, :roots)
  if haskey(roots, name)
    return PathNode(m, name, [])
  else
    # Fall back to normal field access
    return getfield(m, name)
  end
end

function Base.getproperty(node::PathNode, name::Symbol)
  # Verify that the requested child exists in the actual tree
  tree = getfield(node, :mera).roots[getfield(node, :root)]
  for seg in getfield(node, :segments)
    tree = tree.children[seg]
  end
  child_name = String(name)
  if haskey(tree.children, child_name)
    # Child exists - return a new PathNode with the additional segment
    return PathNode(
      getfield(node, :mera),
      getfield(node, :root),
      [getfield(node, :segments); child_name],
    )
  else
    throw(
      ArgumentError(
        "No child named '$name' under path '$(join(getfield(node, :segments), "."))' for root '$(getfield(node, :root))'",
      ),
    )
  end
end

"""
    (node::PathNode)() -> String

Return the absolute path corresponding to this `PathNode`.
The root's base path must have been set with `set_base!`.
"""
function (node::PathNode)()
  if !haskey(getfield(node, :mera).bases, getfield(node, :root))
    throw(
      ArgumentError(
        "Base path not set for root '$(getfield(node, :root))'. Use set_base! first.",
      ),
    )
  end
  base = getfield(node, :mera).bases[getfield(node, :root)]
  # Join the segments using the filesystem separator
  return joinpath(base, join(getfield(node, :segments), "/"))
end

# pretty printing for PathNode
function Base.show(io::IO, node::PathNode)
  print(
    io,
    "PathNode(:",
    getfield(node, :root),
    ", [\"",
    join(getfield(node, :segments), "\", \""),
    "\"])",
  )
end

####################################################################################################
# Path resolution (traditional API)
####################################################################################################

"""
    path(mera::Mera, root::Symbol, key::String) -> String

Return the absolute path for a directory identified by a dot‑separated key
relative to the given root. The root must have its base path set.
"""
function path(mera::Mera, root::Symbol, key::String)
  if !haskey(mera.roots, root)
    throw(ArgumentError("Root '$root' not found in config"))
  end
  if !haskey(mera.bases, root)
    throw(ArgumentError("Base path not set for root '$root'. Use set_base! first."))
  end
  parts = split(key, '.')
  node = mera.roots[root]
  for p in parts
    if !haskey(node.children, p)
      throw(ArgumentError("Key part '$p' not found in path '$key' for root '$root'"))
    end
    node = node.children[p]
  end
  return joinpath(mera.bases[root], node.relpath)
end

"""
    path(mera::Mera, key::String) -> String

Return the absolute path for a key that includes the root name as its first component,
e.g. `"data.orig.hmgcr.csv"`.
"""
function path(mera::Mera, key::String)
  parts = split(key, '.')
  if isempty(parts)
    throw(ArgumentError("Empty key"))
  end
  root = Symbol(parts[1])
  rest = join(parts[2:end], '.')
  return path(mera, root, rest)
end

####################################################################################################
# Global default instance
####################################################################################################

const DEFAULT = Ref{Mera}()

"""
    set_default!(mera::Mera)

Set the global default `Mera` instance used by the single‑argument `path` function.
"""
function set_default!(mera::Mera)
  DEFAULT[] = mera
  return mera
end

"""
    load_default!(config_file::String; bases::Dict{Symbol,String}=Dict{Symbol,String}()) -> Mera

Load a configuration and set it as the global default.
Equivalent to `set_default!(load(config_file; bases=bases))`.
"""
function load_default!(
  config_file::String;
  bases::Dict{Symbol,String} = Dict{Symbol,String}(),
)
  mera = load(config_file; bases = bases)
  set_default!(mera)
  return mera
end

"""
    path(key::String) -> String

Return the absolute path using the global default `Mera` instance.
Throws an error if no default has been set.
"""
function path(key::String)
  if !isassigned(DEFAULT)
    throw(ErrorException("No default Mera instance set. Call load_default! first."))
  end
  return path(DEFAULT[], key)
end

####################################################################################################
# Directory creation
####################################################################################################

function _ensure_tree(tree::RelTree, base::String)
  dir = joinpath(base, tree.relpath)
  mkpath(dir)
  for (_, child) in tree.children
    _ensure_tree(child, base)
  end
end

"""
    ensure(mera::Mera, root::Symbol)

Create all directories for the given root (base path must be set).
"""
function ensure(mera::Mera, root::Symbol)
  if !haskey(mera.bases, root)
    throw(ArgumentError("Base path not set for root '$root'"))
  end
  base = mera.bases[root]
  _ensure_tree(mera.roots[root], base)
end

"""
    ensure(mera::Mera)

Create directories for all roots that have a base path set.
"""
function ensure(mera::Mera)
  for root in keys(mera.roots)
    if haskey(mera.bases, root)
      ensure(mera, root)
    else
      @warn "Skipping root '$root' because base path is not set."
    end
  end
end

####################################################################################################
# Mirror directory structure
####################################################################################################

function _mirror_tree(tree::RelTree, src_base, dst_base)
  src_dir = joinpath(src_base, tree.relpath)
  dst_dir = joinpath(dst_base, tree.relpath)
  mkpath(dst_dir)
  # only recreates the directory structure; does not copy files
  for (_, child) in tree.children
    _mirror_tree(child, src_base, dst_base)
  end
end

"""
    mirror(mera::Mera, src_root::Symbol, dst_root::Symbol)

Recreate the directory tree of `src_root` under `dst_root`.
Both roots must have their base paths set.
"""
function mirror(mera::Mera, src_root::Symbol, dst_root::Symbol)
  if !haskey(mera.bases, src_root) || !haskey(mera.bases, dst_root)
    throw(ArgumentError("Base paths not set for both roots"))
  end
  src_base = mera.bases[src_root]
  dst_base = mera.bases[dst_root]
  _mirror_tree(mera.roots[src_root], src_base, dst_base)
end

####################################################################################################
# Pretty display for Mera and RelTree
####################################################################################################

function Base.show(io::IO, tree::RelTree)
  println(io, "", tree.relpath == "" ? "." : tree.relpath)
  _print_tree(io, tree, "  ")
end

function _print_tree(io::IO, tree::RelTree, indent)
  for name in sort(collect(keys(tree.children)))
    child = tree.children[name]
    println(io, indent, "├─ ", name)
    _print_tree(io, child, indent * "   ")
  end
end

function Base.show(io::IO, m::Mera)
  println(io, "Mera project with roots:")
  for (root, tree) in m.roots
    println(io, "  :$root →")
    show(io, tree)
  end
  println(io, "Bases set: ", join(keys(m.bases), ", "))
end

####################################################################################################

end # module

####################################################################################################

# require

function find_in_path(name::String)
    isabspath(name) && return name
    isfile(name) && return abspath(name)
    base = name
    if endswith(name,".jl")
        base = name[1:end-3]
    else
        name = string(base,".jl")
        isfile(name) && return abspath(name)
    end
    for prefix in [Pkg.dir(), LOAD_PATH]
        path = joinpath(prefix, name)
        isfile(path) && return abspath(path)
        path = joinpath(prefix, base, "src", name)
        isfile(path) && return abspath(path)
        path = joinpath(prefix, name, "src", name)
        isfile(path) && return abspath(path)
    end
    return nothing
end

find_in_node1_path(name) = myid()==1 ?
    find_in_path(name) : remotecall_fetch(1, find_in_path, name)

# Store list of files and their load time
package_list = (ByteString=>Float64)[]
# to synchronize multiple tasks trying to require something
package_locks = (ByteString=>Any)[]
require(fname::String) = require(bytestring(fname))
require(f::String, fs::String...) = (require(f); for x in fs require(x); end)

# only broadcast top-level (not nested) requires and reloads
toplevel_load = true

function require(name::String)
    path = find_in_node1_path(name)
    path == nothing && error("$name not found")

    if myid() == 1 && toplevel_load
        refs = { @spawnat p _require(path) for p in filter(x->x!=1, procs()) }
        _require(path)
        for r in refs; wait(r); end
    else
        _require(path)
    end
    nothing
end

function _require(path)
    global toplevel_load
    if haskey(package_list,path)
        wait(package_locks[path])
    else
        last = toplevel_load
        toplevel_load = false
        reload_path(path)
        toplevel_load = last
    end
end

function reload(name::String)
    global toplevel_load
    path = find_in_node1_path(name)
    path == nothing && error("$name not found")
    refs = nothing
    if myid() == 1 && toplevel_load
        refs = { @spawnat p reload_path(path) for p in filter(x->x!=1, procs()) }
    end
    last = toplevel_load
    toplevel_load = false
    reload_path(path)
    toplevel_load = last
    if refs !== nothing
        for r in refs; wait(r); end
    end
    nothing
end

# remote/parallel load

include_string(txt::ByteString, fname::ByteString) =
    ccall(:jl_load_file_string, Any, (Ptr{Uint8},Ptr{Uint8}), txt, fname)

include_string(txt::ByteString) = include_string(txt, "string")

function source_path(default::Union(String,Nothing)="")
    t = current_task()
    while true
        s = t.storage
        if !is(s, nothing) && haskey(s, :SOURCE_PATH)
            return s[:SOURCE_PATH]
        end
        if is(t, t.parent)
            return default
        end
        t = t.parent
    end
end

macro __FILE__() source_path() end

function include_from_node1(path::String)
    prev = source_path(nothing)
    path = (prev == nothing) ? abspath(path) : joinpath(dirname(prev),path)
    tls = task_local_storage()
    tls[:SOURCE_PATH] = path
    local result
    try
        if myid()==1
            # sleep a bit to process file requests from other nodes
            nprocs()>1 && sleep(0.005)
            result = Core.include(path)
            nprocs()>1 && sleep(0.005)
        else
            include_string(remotecall_fetch(1, readall, path), path)
            # don't bother sending last value for remote include
            result = nothing
        end
    finally
        if prev == nothing
            delete!(tls, :SOURCE_PATH)
        else
            tls[:SOURCE_PATH] = prev
        end
    end
    result
end

function reload_path(path::String)
    had = haskey(package_list, path)
    if !had
        package_locks[path] = RemoteRef()
    end
    package_list[path] = time()
    tls = task_local_storage()
    prev = pop!(tls, :SOURCE_PATH, nothing)
    try
        eval(Main, :(Base.include_from_node1($path)))
    catch e
        had || delete!(package_list, path)
        rethrow(e)
    finally
        if prev != nothing
            tls[:SOURCE_PATH] = prev
        end
    end
    if !isready(package_locks[path])
        put(package_locks[path],nothing)
    end
    nothing
end

function evalfile(path::String, args::Array = {})
    return eval(Module(:__anon__),
                Expr(:toplevel,:(ARGS=$args),:(include($path))))
end

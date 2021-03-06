@pyimport rhodium
@pyimport prim
@pyimport pandas as pd

# TBD: see if it works to simply call __init__(function) without storing the julia function
py"""
from rhodium import *
class JuliaModel(Model):
    
    def __init__(self, function, **kwargs):
        super(JuliaModel, self).__init__(self._evaluate)
        self.j_function = function
        
    def _evaluate(self, **kwargs):
        result = self.j_function(**kwargs)
        return result
"""

# Wrapper classes have a pyo field that holds a PyObject
abstract type Wrapper end

# Helper function for use with map(pyo, list-of-Wrappers)
pyo(obj) = obj.pyo

#
# Wrap Python objects in a thin julia wrapper so we can use the type system
#
struct Model <: Wrapper
    pyo::PyObject

    function Model(f)
        return new(py"JuliaModel($f)")
    end
end

struct Parameter <: Wrapper
    pyo::PyObject
    
    function Parameter(name::AbstractString, default_value::Any=nothing)
        return new(rhodium.Parameter(name, default_value=default_value))
    end
end

Parameter(name::Symbol, default_value::Any=nothing) = Parameter(String(name), default_value)

Parameter(pair::Pair{Symbol, Any}) = Parameter(pair.first, pair.second)


struct Response <: Wrapper
    pyo::PyObject

    function Response(name::AbstractString, kind::Symbol)
        kind in (:MAXIMIZE, :MINIMIZE, :INFO) || error("The kind argument must be either :MAXIMIZE or :MINIMIZE")

        return new(rhodium.Response(name, rhodium.Response[kind]))
    end
    
end

abstract type Lever  <: Wrapper end

struct IntegerLever <: Lever
    pyo::PyObject

    function IntegerLever(name::AbstractString, min_value::Int, max_value::Int; length::Int=1)
        return new(rhodium.IntegerLever(name, min_value, max_value, length=length))
    end
end

struct RealLever <: Lever
    pyo::PyObject

    function RealLever(name::AbstractString, min_value::Float64, max_value::Float64; length::Int=1)
        return new(rhodium.RealLever(name, min_value, max_value, length=length))
    end
end

struct CategoricalLever <: Lever
    pyo::PyObject

    function CategoricalLever(name::AbstractString, categories)
        return new(rhodium.CategoricalLever(name, categories))
    end
end

struct PermutationLever <: Lever
    pyo::PyObject

    function PermutationLever(name::AbstractString, options)
        return new(rhodium.PermutationLever(name, options))
    end
end

struct SubsetLever <: Lever
    pyo::PyObject

    function SubsetLever(name::AbstractString, options, size)
        return new(rhodium.SubsetLever(name, options, size))
    end
end

struct Constraint <: Wrapper
    pyo::PyObject

    function Constraint(con::AbstractString)
        return new(rhodium.Constraint(con))
    end

end

Constraint(con::Symbol) = Constraint(String(con))

struct Brush <: Wrapper
    pyo::PyObject

    function Brush(def::AbstractString)
        return new(rhodium.Brush(def))
    end
end

# In rhodium, a dataset is a subclass of list that holds only dicts.
struct DataSet <: Wrapper
    pyo::PyObject   # a python DataSet

    function DataSet(pyo::PyObject)
        return new(pyo)
    end

    # A string argument is interpreted in the python func as a file to load
    function DataSet(data::Union{AbstractString, AbstractArray}=nothing)
        new(rhodium.DataSet(data))
    end
end

Base.length(ds::DataSet) = length(ds.pyo)

Base.start(iter::DataSet) = 1

Base.next(ds::DataSet, state) = ds.pyo[state], state + 1

Base.done(ds::DataSet, state) = state > length(ds)

Base.getindex(ds::DataSet, i::Int) = ds.pyo[i]

function Base.findmax(ds::DataSet, key::Symbol)
    return pycall(ds.pyo[:find_max], PyDict, String(key))
end

function Base.findmin(ds::DataSet, key::Symbol)
    return pycall(ds.pyo[:find_min], PyDict, String(key))
end

function Base.find(ds::DataSet, expr; inverse=false)
    return pycall(ds.pyo[:find], PyObject, expr, inverse=inverse)
end

# Create a NamedTuple type expression from the contents of the given dict,
# returning the type or, if evaluate == false, the type expression.
function make_NT_type(dict::Union{Dict, PyDict}; evaluate=true)
    names = map(Symbol, keys(dict))
    types = map(typeof, values(dict))
    col_exprs = [:($name::$etype) for (etype, name) in zip(types, names)]
    t_expr = NamedTuples.make_tuple(col_exprs)
    return evaluate ? eval(t_expr) : t_expr
end

function named_tuple(d::Union{Dict, PyDict})
    T = make_NT_type(d)
    return T(values(d)...)
end

function named_tuples(ds::DataSet)
    T = make_NT_type(ds[1])
    output = [T(values(dict)...) for dict in ds]
end

#
# To some, "type piracy". To others, useful conversion methods. ;~)
#
DataFrames.DataFrame(ds::DataSet) = DataFrames.DataFrame(named_tuples(ds))

function DataStructures.Dict(nt::NamedTuple) 
    return DataStructures.Dict{Symbol, Any}(collect(k => v for (k, v) in zip(keys(nt), values(nt))))
end

function DataStructures.Dict(pydict::PyDict)
    return DataStructures.Dict(Symbol(k) => v for (k, v) in pydict)
end

function pandas_dataframe(ds::DataSet; include=nothing, exclude=nothing)
    # TBD: Convert directly to np.recarray? That's the end result 
    # on the python side, so we'd avoid building 2 intermediate DFs.
    df = DataFrame(ds)

    # However... numpy's drop_names is failing, complaining about
    # 'data type not understood',). We process the include/exclude 
    # args here before passing the data to python.
    if include != nothing
        if ! (include isa AbstractArray)
            include = [include]
        end

        colnames = [Symbol(name) for name in include]
        df = df[colnames]
    end
    
    if exclude != nothing
        if ! (exclude isa AbstractArray)
            exclude = [exclude]
        end
        
        colnames = collect(setdiff(Set(names(df)), Set(map(Symbol, exclude))))
        df = df[colnames]
    end

    dict = Dict(k => df[k] for k in names(df))
    pandasDF = pd.DataFrame(dict)
    return pandasDF
end

"""
    set_parameters!(m::Model, parameters::Vector{Parameter})
    set_parameters!{T<:Union{Symbol,Pair{Symbol,Any}}}(m::Model, parameters::Vector{T})

Set model parameters using one of these forms:

  set_parameters!(m, [Parameter("a"), Parameter("b")...])

  # create parameters with the given names. Default values are `nothing`
  set_parameters!(m, [:a, :b, "c", ...])

  # create parameters with default values
  set_parameters!(m, [:name => 1, :name2 => 10.6])

"""
function set_parameters!(m::Model, parameters::Vector{Parameter})
    m.pyo[:parameters] = map(pyo, parameters)
    return nothing
end

set_parameters!{T<:Union{Symbol,Pair{Symbol,Any}}}(m::Model, v::Vector{T}) = set_parameters!(m, map(Parameter, v))

function set_responses!(m::Model, responses::Vector{Response})
    m.pyo[:responses] = map(pyo, responses)
    return nothing
end

function set_responses!(m::Model, responses::Vector{Pair{Symbol,Symbol}})
    m.pyo[:responses] = map(responses) do i        
        i.second in (:MAXIMIZE, :MINIMIZE, :INFO) || error("The kind argument must be either :MAXIMIZE or :MINIMIZE")
        return rhodium.Response(String(i.first), rhodium.Response[i.second])
    end
    nothing
end

function set_levers!(m::Model, levers::Vector{T}) where T <: Lever
    m.pyo[:levers] = map(pyo, levers)
    return nothing
end

function set_constraints!(m::Model, constraints::Vector{Constraint})
    m.pyo[:constraints] = map(pyo, constraints)
    return nothing
end

set_constraints!(m::Model, v::Vector) = set_constraints!(m, map(Constraint, v))

function set_uncertainties!(m::Model, uncertainties::Vector{Pair{Symbol,T}} where T)
    m.pyo[:uncertainties] = map(uncertainties) do i
        if i.second isa Uniform{Float64}
            rhodium.UniformUncertainty(string(i.first), i.second.a, i.second.b)
        else
            error("Distribution type $(typeof(i.second)) is not currently supported by Rhodium")
        end
    end
    return nothing
end

function sample_lhs(m::Model, nsamples::Int)
    # returns a rhodium DataSet (a subclass of list), which holds (python) OrderedDicts
    py_output = pycall(rhodium.sample_lhs, PyObject, m.pyo, nsamples)
    return DataSet(py_output)
end

function optimize(m::Model, algorithm, trials)
    py_output = pycall(rhodium.optimize, PyObject, m.pyo, algorithm, trials)
    return DataSet(py_output)
end

function evaluate(m::Model, policy::Dict)
    return pycall(rhodium.evaluate, PyDict, m.pyo, policy)
end

# If passed a named tuple, return result as one, too
evaluate(m::Model, policy::NamedTuple) = named_tuple(evaluate(m, Dict(policy)))

function evaluate(m::Model, policies::Vector)
    py_output = pycall(rhodium.evaluate, PyObject, m.pyo, policies)
    return DataSet(py_output)
end

function apply(ds::DataSet, expr; update=true)
    res = pycall(ds.pyo[:apply], PyVector, expr, update)
    return collect(res)
end

# function apply(m::Model, results::Vector{T} where T<:NamedTuple, expr; update=false)
#     x = [Dict(k => v for (k,v) in zip(keys(result), values(result))) for result in results])
#     res = apply(whatever, expr, update=update)
#     return res
# end

function _add_brush!(kwargs, brush)
    if brush != nothing
        push!(kwargs, (:brush, map(pyo, brush)))
    end
end

function scatter2d(m::Model, ds::DataSet; brush=nothing, kwargs...)
    _add_brush!(kwargs, brush)
    return rhodium.scatter2d(m.pyo, ds.pyo; kwargs...)
end

function scatter3d(m::Model, ds::DataSet; brush=nothing, kwargs...)
    _add_brush!(kwargs, brush)
    return rhodium.scatter3d(m.pyo, ds.pyo; kwargs...)
end

function pairs(m::Model, ds::DataSet; brush=nothing, kwargs...)
    _add_brush!(kwargs, brush)
    return rhodium.pairs(m.pyo, ds.pyo; kwargs...)
end

function parallel_coordinates(m::Model, ds::DataSet; brush=nothing, kwargs...)
    _add_brush!(kwargs, brush)
    return rhodium.parallel_coordinates(m.pyo, ds.pyo; kwargs...)
end

function use_seaborn(style="darkgrid")
    @pyimport seaborn as sns
    sns.set()
    sns.set_style(style)
end

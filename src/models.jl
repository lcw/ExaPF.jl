export PolarForm, bounds, powerflow
export State, Control, Parameters, NumberOfState, NumberOfControl

"""
    AbstractStructure

The user may specify a mapping to the single input vector `x` for AD.

"""
abstract type AbstractStructure end

"""
    AbstractFormulation

Second layer of the package, implementing the interface between
the first layer (the topology of the network) and the
third layer (implementing the callbacks for the optimization solver).

"""
abstract type AbstractFormulation end

"""
    AbstractFormAttribute

Attributes attached to an `AbstractFormulation`.
"""
abstract type AbstractFormAttribute end

"Number of states attached to a particular formulation."
struct NumberOfState <: AbstractFormAttribute end

"Number of controls attached to a particular formulation."
struct NumberOfControl <: AbstractFormAttribute end

"""
    AbstractVariable

Variables corresponding to a particular formulation.
"""
abstract type AbstractVariable end

"""
    State <: AbstractVariable

All variables `x` depending on the variables `Control` `u` through
a non-linear equation `g(x, u) = 0`.

"""
struct State <: AbstractVariable end

"""
    Control <: AbstractVariable

Implement the independent variables used in the reduced-space
formulation.

"""
struct Control <: AbstractVariable end

"""
    PhysicalState <: AbstractVariable

All physical variables describing the current physical state
of the underlying network.

`PhysicalState` variables are encoded in a `AbstractNetworkBuffer`,
storing all the physical values needed to describe the current
state of the network.

"""
struct PhysicalState <: AbstractVariable end

# Templates
"""
    get(form::AbstractFormulation, attr::AbstractFormAttribute)

Return value of attribute `attr` attached to the particular
formulation `form`.

## Examples

```julia
get(form, NumberOfState())
get(form, NumberOfControl())

```
"""
function get end

"""
    setvalues!(form::AbstractFormulation, attr::PS.AbstractNetworkAttribute, values)

Update inplace the attribute's values specified by `attr`.

## Examples

```julia
setvalues!(form, ActiveLoad(), new_ploads)
setvalues!(form, ReactiveLoad(), new_qloads)

```
"""
function setvalues! end

"""
    bounds(form::AbstractFormulation, var::AbstractVariable)

Return the bounds attached to the variable `var`.

    bounds(form::AbstractFormulation, func::Function)

Return a tuple of vectors `(lb, ub)` specifying the admissible range
of the constraints specified by the function `cons_func`.

## Examples

```julia
u_min, u_max = bounds(form, Control())
h_min, h_max = bounds(form, reactive_power_constraints)

```
"""
function bounds end

"""
    initial(form::AbstractFormulation, var::AbstractVariable)

Return an initial position for the variable `var`.

## Examples

```julia
u₀ = initial(form, Control())
x₀ = initial(form, State())

```
"""
function initial end

"""
    powerflow(form::AbstractFormulation,
              jacobian::AutoDiff.StateJacobian,
              buffer::AbstractNetworkBuffer,
              algo::AbstractNonLinearSolver;
              kwargs...) where VT <: AbstractVector

Solve the power flow equations `g(x, u) = 0` w.r.t. the state `x`,
using a Newton-Raphson algorithm.
The powerflow equations are specified in the formulation `form`.
The current state `x` and control `u` are specified in
`buffer`. The object `buffer` is modified inplace.

The algorithm stops when a tolerance `tol` or a maximum number of
irations `maxiter` are reached (these parameters being specified
in the argument `algo`).

## Arguments

* `form::AbstractFormulation`: formulation of the power flow equation
* `jacobian::AutoDiff.StateJacobian`: Jacobian
* `buffer::AbstractNetworkBuffer`: buffer storing current state `x` and control `u`
* `algo::AbstractNonLinearSolver`: non-linear solver. Currently only `NewtonRaphson` is being implemented.

## Optional arguments

* `linear_solver::AbstractLinearSolver` (default `DirectSolver()`): solver to solve the linear systems ``J x = y`` arising at each iteration of the Newton-Raphson algorithm.

"""
function powerflow end

# Cost function
"""
    cost_production(form::AbstractFormulation, pg::AbstractVector)::Float64

Get operational cost corresponding to the active power generation
specified in the vector `pg`.

"""
function cost_production end

# Generic constraints
"""
    size_constraint(cons_func::Function)::Bool
Return whether the function `cons_func` is a supported constraint
in the powerflow model.
"""
function is_constraint end

"""
    size_constraint(form::AbstractFormulation, cons_func::Function)::Int

Get number of constraints specified by the function `cons_func`
in the formulation `form`.
"""
function size_constraint end

"""
    voltage_magnitude_constraints(form::AbstractFormulation, cons::AbstractVector, buffer::AbstractNetworkBuffer)

Evaluate the constraints porting on the state `x`, as a
function of `x` and `u`. The result is stored inplace, inside `cons`.
"""
function voltage_magnitude_constraints end

"""
    active_power_constraints(form::AbstractFormulation, cons::AbstractVector, buffer::AbstractNetworkBuffer)

Evaluate the constraints on the **active power production** at the generators
that are not already taken into account in the box constraints.
The result is stored inplace, inside the vector `cons`.
"""
function active_power_constraints end

"""
    reactive_power_constraints(form::AbstractFormulation, cons::AbstractVector, buffer::AbstractNetworkBuffer)

Evaluate the constraints on the **reactive power production** at the generators.
The result is stored inplace, inside the vector `cons`.
"""
function reactive_power_constraints end

"""
    flow_constraints(form::AbstractFormulation, cons::AbstractVector, buffer::AbstractNetworkBuffer)

Evaluate the thermal limit constraints porting on the lines of the network.

The result is stored inplace, inside the vector `cons`.
"""
function flow_constraints end

"""
    power_balance(form::AbstractFormulation, cons::AbstractVector, buffer::AbstractNetworkBuffer)

Evaluate the power balance in the network.

The result is stored inplace, inside the vector `cons`.

"""
function power_balance end


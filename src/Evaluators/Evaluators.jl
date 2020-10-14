
import Base: show

"""
    AbstractNLPEvaluator

AbstractNLPEvaluator implements the bridge between the
problem formulation (see `AbstractFormulation`) and the optimization
solver. Once the problem formulation bridged, the evaluator allows
to evaluate in a straightfoward fashion the objective and the different
constraints, but also the corresponding gradient and Jacobian objects.

"""
abstract type AbstractNLPEvaluator end

"""
    n_variables(nlp::AbstractNLPEvaluator)
Get the number of variables in the problem.
"""
function n_variables end

"""
    n_constraints(nlp::AbstractNLPEvaluator)
Get the number of constraints in the problem.
"""
function n_constraints end

"""
    objective(nlp::AbstractNLPEvaluator, u)::Float64

Evaluate the objective at point `u`.
"""
function objective end

"""
    gradient!(nlp::AbstractNLPEvaluator, g, u)

Evaluate the gradient of the objective at point `u`. Store
the result inplace in the vector `g`, which should have the same
dimension as `u`.

"""
function gradient! end

"""
    constraint!(nlp::AbstractNLPEvaluator, cons, u)

Evaluate the constraints of the problem at point `u`. Store
the result inplace, in the vector `cons`.
The vector `cons` should have the same dimension as the result
returned by `n_constraints(nlp)`.

"""
function constraint! end

"""
    jacobian_structure!(nlp::AbstractNLPEvaluator, rows, cols)

Return the sparsity pattern of the Jacobian matrix.
"""
function jacobian_structure! end

"""
    jacobian!(nlp::ReducedSpaceEvaluator, jac, u)

Evaluate the Jacobian of the problem at point `u`. Store
the result inplace, in the vector `jac`.
"""
function jacobian! end

"""
    hessian!(nlp::AbstractNLPEvaluator, hess, u)

Evaluate the Hessian of the problem at point `u`. Store
the result inplace, in the vector `hess`.

"""
function hessian! end

include("common.jl")
include("reduced_evaluator.jl")
include("penalty.jl")
include("scaling.jl")

function _check(val, val_min, val_max)
    violated_inf = findall(val .< val_min)
    violated_sup = findall(val .> val_max)
    n_inf = length(violated_inf)
    n_sup = length(violated_sup)
    err_inf = norm(val_min[violated_inf] .- val[violated_inf], Inf)
    err_sup = norm(val[violated_sup] .- val_max[violated_sup] , Inf)
    return (n_inf, err_inf, n_sup, err_sup)
end

function primal_infeasibility(nlp::AbstractNLPEvaluator, cons)
    (n_inf, err_inf, n_sup, err_sup) = _check(cons, nlp.g_min, nlp.g_max)
    return max(err_inf, err_sup)
end


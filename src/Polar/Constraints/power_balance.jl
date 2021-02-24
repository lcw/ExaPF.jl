is_constraint(::typeof(power_balance)) = true

function _power_balance!(F, v_m, v_a, pinj, qinj,
                         ybus_re, ybus_im,
                         pv, pq, ref, nbus)
    npv = length(pv)
    npq = length(pq)
    if isa(F, Array)
        kernel! = residual_kernel!(KA.CPU())
    else
        kernel! = residual_kernel!(KA.CUDADevice())
    end
    ev = kernel!(F, v_m, v_a,
                 ybus_re.nzval, ybus_re.colptr, ybus_re.rowval,
                 ybus_im.nzval,
                 pinj, qinj, pv, pq, nbus,
                 ndrange=npv+npq)
    wait(ev)
end

function power_balance(polar::PolarForm, cons, buffer::PolarNetworkState)
    nbus = PS.get(polar.network, PS.NumberOfBuses())
    ngen = PS.get(polar.network, PS.NumberOfGenerators())
    npv = PS.get(polar.network, PS.NumberOfPVBuses())
    npq = PS.get(polar.network, PS.NumberOfPQBuses())
    # Indexing
    ref = polar.indexing.index_ref
    pv = polar.indexing.index_pv
    pq = polar.indexing.index_pq
    Vm, Va, pbus, qbus = buffer.vmag, buffer.vang, buffer.pinj, buffer.qinj
    ybus_re, ybus_im = get(polar.topology, PS.BusAdmittanceMatrix())

    fill!(cons, 0.0)
    _power_balance!(
        cons, Vm, Va, pbus, qbus,
        ybus_re, ybus_im,
        pv, pq, ref, nbus
    )
end

function power_balance(polar::PolarForm, cons, vm, va, pbus, qbus)
    nbus = get(polar, PS.NumberOfBuses())
    ref = polar.indexing.index_ref
    pv = polar.indexing.index_pv
    pq = polar.indexing.index_pq
    ybus_re, ybus_im = get(polar.topology, PS.BusAdmittanceMatrix())

    fill!(cons, 0.0)
    _power_balance!(
        cons, vm, va, pbus, qbus,
        ybus_re, ybus_im,
        pv, pq, ref, nbus
    )
end

function size_constraint(polar::PolarForm{T, IT, VT, MT}, ::typeof(power_balance)) where {T, IT, VT, MT}
    npv = PS.get(polar.network, PS.NumberOfPVBuses())
    npq = PS.get(polar.network, PS.NumberOfPQBuses())
    return 2 * npq + npv
end

function bounds(polar::PolarForm{T, IT, VT, MT}, ::typeof(power_balance)) where {T, IT, VT, MT}
    m = size_constraint(polar, power_balance)
    return xzeros(VT, m) , xzeros(VT, m)
end

function matpower_jacobian(polar::PolarForm, ::State, ::typeof(power_balance), V)
    nbus = get(polar, PS.NumberOfBuses())
    pf = polar.network
    ref = pf.ref
    pv = pf.pv
    pq = pf.pq
    Ybus = pf.Ybus

    dSbus_dVm, dSbus_dVa = _matpower_residual_jacobian(V, Ybus)
    j11 = real(dSbus_dVa[[pv; pq], [pv; pq]])
    j12 = real(dSbus_dVm[[pv; pq], pq])
    j21 = imag(dSbus_dVa[pq, [pv; pq]])
    j22 = imag(dSbus_dVm[pq, pq])

    return [j11 j12; j21 j22]
end
function matpower_jacobian(polar::PolarForm, ::Control, ::typeof(power_balance), V)
    nbus = get(polar, PS.NumberOfBuses())
    pf = polar.network
    ref = pf.ref
    pv = pf.pv
    pq = pf.pq
    Ybus = pf.Ybus

    dSbus_dVm, _ = _matpower_residual_jacobian(V, Ybus)
    j11 = real(dSbus_dVm[[pv; pq], [ref; pv; pv]])
    j21 = imag(dSbus_dVm[pq, [ref; pv; pv]])
    return [j11; j21]
end

function jacobian_sparsity(polar::PolarForm, ::typeof(power_balance), v::AbstractVariable)
    nbus = get(polar, PS.NumberOfBuses())
    Vre = Float64[i for i in 1:nbus]
    Vim = Float64[i for i in nbus+1:2*nbus]
    V = Vre .+ im .* Vim
    return matpower_jacobian(polar, v, power_balance, V)
end

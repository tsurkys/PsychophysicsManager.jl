# The seven psychometric functions (Kingdom & Prins 2016, ch. 4), by the names a session
# file and a `CurveFit` store. Each rises from 0 to 1 as F(x; α, β), and a curve is
# ψ(x) = γ + (1 − γ − λ) F(x; α, β).

using StatsFuns: normcdf

# A function as a standard form `rise` of z = β (t − a), on the axis t = x with a = α, or,
# for a `logarithmic` one, t = log x with a = log α — the Weibull and the Quick are
# functions of x / α. `steepness` is the steepest rise of the standard form relative to
# the logistic's 1/4, so that a slope means the same steepness whatever the function.
struct PsychometricShape{R}
    rise::R
    logarithmic::Bool
    steepness::Float64
end

const PSYCHOMETRIC_SHAPES = (
    logistic          = PsychometricShape(z -> 1 / (1 + exp(-z)), false, 1.0),
    cumulative_normal = PsychometricShape(z -> normcdf(z), false, 4 / sqrt(2π)),
    hyperbolic_secant = PsychometricShape(z -> 2 / π * atan(exp(π / 2 * z)), false, 2.0),
    # The Gumbel and the log-Quick are those of the base-10 logarithm of an intensity,
    # which is the level they are given
    gumbel            = PsychometricShape(z -> -expm1(-exp10(z)), false, 4 * log(10) / ℯ),
    log_quick         = PsychometricShape(z -> -expm1(-log(2) * exp10(z)), false,
                                          4 * log(10) / ℯ),
    weibull           = PsychometricShape(z -> -expm1(-exp(z)), true, 4 / ℯ),
    quick             = PsychometricShape(z -> -expm1(-log(2) * exp(z)), true, 4 / ℯ),
)

"""
    PSYCHOMETRIC_FUNCTIONS

The names of the psychometric functions a fit ([`fit_psychometric_curve`](@ref)) and
[`Psi`](@ref) take (Kingdom & Prins 2016, ch. 4), with F(x; α, β) rising from 0 to 1:

- `:logistic` — 1 / (1 + e^(−β(x − α)))
- `:cumulative_normal` — Φ(β(x − α))
- `:hyperbolic_secant` — (2/π) atan(e^(π/2 · β(x − α)))
- `:gumbel` — 1 − exp(−10^(β(x − α)))
- `:log_quick` — 1 − 2^(−10^(β(x − α)))
- `:weibull` — 1 − exp(−(x/α)^β)
- `:quick` — 1 − 2^(−(x/α)^β)

The Gumbel and the log-Quick are the Weibull and the Quick of the base-10 logarithm of an
intensity, so a design gives them that logarithm as its level. The Weibull and the Quick
take levels of 0 and above and a positive threshold.
"""
const PSYCHOMETRIC_FUNCTIONS = keys(PSYCHOMETRIC_SHAPES)

function psychometric_shape(model::Symbol)
    haskey(PSYCHOMETRIC_SHAPES, model) || throw(ArgumentError(
        "Unknown psychometric function :$model. Choose one of " *
        join(":" .* string.(PSYCHOMETRIC_FUNCTIONS), ", ") * "."))
    return PSYCHOMETRIC_SHAPES[model]
end

# The axis a level sits on. A logarithmic function is 0 at and below a level of 0.
axis_value(shape::PsychometricShape, x::Real) =
    shape.logarithmic ? (x > 0 ? log(x) : -Inf) : Float64(x)

# The axis's location of a threshold
axis_location(shape::PsychometricShape, alpha::Real) =
    shape.logarithmic ? log(alpha) : Float64(alpha)

# F at a point `t` of the axis, given the location `a` there and the slope
function rise_at(shape::PsychometricShape, t::Real, a::Real, slope::Real)
    z = slope * (t - a)
    # A level of 0 under a logarithmic function: −∞ times a slope of 0
    isnan(z) && return 0.0
    return shape.rise(z)
end

"""
    psychometric_value(model::Symbol, x, alpha, beta, gamma, lambda) -> Float64

The psychometric function `model` ([`PSYCHOMETRIC_FUNCTIONS`](@ref)) at level `x`:
γ + (1 − γ − λ) F(x; α, β).
"""
psychometric_value(model::Symbol, x::Real, alpha::Real, beta::Real, gamma::Real,
                   lambda::Real) =
    psychometric_value(psychometric_shape(model), x, alpha, beta, gamma, lambda)

psychometric_value(shape::PsychometricShape, x::Real, alpha::Real, beta::Real,
                   gamma::Real, lambda::Real) =
    gamma + (1 - gamma - lambda) *
            rise_at(shape, axis_value(shape, x), axis_location(shape, alpha), beta)

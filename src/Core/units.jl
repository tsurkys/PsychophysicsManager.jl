# Unit conversion: the units a report shows a
# recorded value in. The record itself stays in the units it was presented in.

const UNIT_CONVERSION_FORMS = (:affine, :log10)

"""
    UnitConversion(label; scale = 1.0, offset = 0.0, form = :affine, formula = "")

How the values of one variable are shown in the units a report uses: plots, summaries
and exports show them converted, under `label` — the full name of the converted
quantity, such as `"Interval difference (arcmin)"`, since two variables in the same
unit still need two names.

`form = :affine` maps a recorded value `x` to `scale * x + offset`; `form = :log10`
maps it to `scale * log10(x) + offset` and accepts only positive values. A marker
offset recorded in pixels on a display of 0.5 minutes of arc per pixel is shown in
degrees by `UnitConversion("Offset (deg)"; scale = 0.5 / 60)`; a contrast in log
units by `UnitConversion("log10 contrast"; form = :log10)`.

When declared from a formula (`"Diff * pixel_arcmin"`), `formula` keeps the right-hand
side as typed so a template resolves anew on another rig, while `scale` and `offset`
keep the resolved numbers for reading the session anywhere. Attach a conversion to a
session with [`set_unit_conversion!`](@ref); a conversion called on a number converts it.
"""
struct UnitConversion
    label::String
    form::Symbol
    scale::Float64
    offset::Float64
    formula::String

    function UnitConversion(label::AbstractString, form::Symbol, scale::Real, offset::Real,
                            formula::AbstractString = "")
        isempty(strip(label)) &&
            throw(ArgumentError("A unit conversion needs a label to show its values under."))
        form in UNIT_CONVERSION_FORMS || throw(ArgumentError(
            "Unknown conversion form :$form; the forms are " *
            "$(join(repr.(UNIT_CONVERSION_FORMS), ", "))."))
        isfinite(scale) && isfinite(offset) || throw(ArgumentError(
            "A conversion's scale and offset must be finite, got scale = $scale, " *
            "offset = $offset."))
        # A zero scale is finite but maps every level to one value, merging
        # conditions the session presented apart
        scale == 0 && throw(ArgumentError("A conversion's scale must not be zero."))
        return new(String(label), form, Float64(scale), Float64(offset), String(strip(formula)))
    end
end

UnitConversion(label::AbstractString; scale::Real = 1.0, offset::Real = 0.0,
               form::Symbol = :affine, formula::AbstractString = "") =
    UnitConversion(label, form, scale, offset, formula)

function (conversion::UnitConversion)(x::Real)
    conversion.form === :affine && return conversion.scale * x + conversion.offset
    x > 0 || throw(DomainError(x,
        "\"$(conversion.label)\" is a logarithmic conversion and takes only positive values."))
    return conversion.scale * log10(x) + conversion.offset
end

"""
    conversion_formula(variable, conversion) -> String

The conversion written out for a reader, e.g. `"Diff (arcmin) = 0.5 * Diff"` or, when
the conversion carries a formula, `"<label> = <formula>"`.
"""
function conversion_formula(variable::Symbol, conversion::UnitConversion)
    isempty(conversion.formula) || return "$(conversion.label) = $(conversion.formula)"
    argument = conversion.form === :log10 ? "log10($variable)" : string(variable)
    (; scale, offset) = conversion
    term = scale == 1 ? argument : "$scale * $argument"
    offset == 0 && return "$(conversion.label) = $term"
    return "$(conversion.label) = $term $(offset < 0 ? '-' : '+') $(abs(offset))"
end

# ── Unit-conversion formula parser ───────────────────────────────────────────
#
# A self-contained parser for linear formulas in one parameter (or its log10)
# over named numeric constants; user text is never passed to Meta.parse or eval.

struct FormulaToken
    kind::Symbol
    text::String
end

abstract type FormulaExpr end

struct FormulaNumber <: FormulaExpr
    value::Float64
end

struct FormulaVar <: FormulaExpr
    name::Symbol
end

struct FormulaUnary <: FormulaExpr
    op::Symbol
    arg::FormulaExpr
end

struct FormulaBinary <: FormulaExpr
    op::Symbol
    left::FormulaExpr
    right::FormulaExpr
end

struct FormulaCall <: FormulaExpr
    func::Symbol
    args::Vector{FormulaExpr}
end

function tokenize_formula(text::AbstractString)
    s = String(text)
    tokens = FormulaToken[]
    i = firstindex(s)
    last_i = lastindex(s)
    while i <= last_i
        c = s[i]
        if isspace(c)
            i = nextind(s, i)
        elseif c == '+'
            push!(tokens, FormulaToken(:plus, "+"))
            i = nextind(s, i)
        elseif c == '-'
            push!(tokens, FormulaToken(:minus, "-"))
            i = nextind(s, i)
        elseif c == '*'
            push!(tokens, FormulaToken(:star, "*"))
            i = nextind(s, i)
        elseif c == '/'
            push!(tokens, FormulaToken(:slash, "/"))
            i = nextind(s, i)
        elseif c == '('
            push!(tokens, FormulaToken(:lparen, "("))
            i = nextind(s, i)
        elseif c == ')'
            push!(tokens, FormulaToken(:rparen, ")"))
            i = nextind(s, i)
        elseif c == ','
            push!(tokens, FormulaToken(:comma, ","))
            i = nextind(s, i)
        elseif ('0' <= c <= '9') || (c == '.' && i < last_i && '0' <= s[nextind(s, i)] <= '9')
            start = i
            has_digits = false
            while i <= last_i && '0' <= s[i] <= '9'
                has_digits = true
                i = nextind(s, i)
            end
            if i <= last_i && s[i] == '.'
                i = nextind(s, i)
                while i <= last_i && '0' <= s[i] <= '9'
                    has_digits = true
                    i = nextind(s, i)
                end
            end
            if i <= last_i && (s[i] == 'e' || s[i] == 'E')
                i = nextind(s, i)
                if i <= last_i && (s[i] == '+' || s[i] == '-')
                    i = nextind(s, i)
                end
                exp_digits = false
                while i <= last_i && '0' <= s[i] <= '9'
                    exp_digits = true
                    i = nextind(s, i)
                end
                exp_digits || throw(ArgumentError(
                    "Invalid number `$(s[start:prevind(s, i)])` in unit conversion formula."))
            end
            raw = s[start:prevind(s, i)]
            (has_digits && tryparse(Float64, raw) !== nothing) || throw(ArgumentError(
                "Invalid number `$raw` in unit conversion formula."))
            push!(tokens, FormulaToken(:number, raw))
        elseif ('A' <= c <= 'Z') || ('a' <= c <= 'z') || c == '_'
            start = i
            i = nextind(s, i)
            while i <= last_i
                ch = s[i]
                (('A' <= ch <= 'Z') || ('a' <= ch <= 'z') || ('0' <= ch <= '9') || ch == '_') ||
                    break
                i = nextind(s, i)
            end
            push!(tokens, FormulaToken(:name, s[start:prevind(s, i)]))
        else
            throw(ArgumentError(
                "Unexpected character `$c` in unit conversion formula \"$text\"."))
        end
    end
    push!(tokens, FormulaToken(:eof, ""))
    return tokens
end

mutable struct FormulaParser
    tokens::Vector{FormulaToken}
    pos::Int
end

peek_token(parser::FormulaParser) = parser.tokens[parser.pos]
advance_token!(parser::FormulaParser) = (tok = parser.tokens[parser.pos]; parser.pos += 1; tok)

function parse_formula(source::AbstractString)
    parser = FormulaParser(tokenize_formula(source), 1)
    expr = parse_expr!(parser, source)
    tok = peek_token(parser)
    tok.kind === :eof || throw(ArgumentError(
        "Unexpected `$(tok.text)` in unit conversion formula \"$source\"."))
    return expr
end

function parse_expr!(parser::FormulaParser, source::AbstractString)
    left = parse_term!(parser, source)
    while true
        kind = peek_token(parser).kind
        if kind === :plus || kind === :minus
            advance_token!(parser)
            right = parse_term!(parser, source)
            left = FormulaBinary(kind === :plus ? :+ : :-, left, right)
        else
            return left
        end
    end
end

function parse_term!(parser::FormulaParser, source::AbstractString)
    left = parse_unary!(parser, source)
    while true
        kind = peek_token(parser).kind
        if kind === :star || kind === :slash
            advance_token!(parser)
            right = parse_unary!(parser, source)
            left = FormulaBinary(kind === :star ? :* : :/, left, right)
        else
            return left
        end
    end
end

function parse_unary!(parser::FormulaParser, source::AbstractString)
    kind = peek_token(parser).kind
    if kind === :plus || kind === :minus
        advance_token!(parser)
        return FormulaUnary(kind === :plus ? :+ : :-, parse_unary!(parser, source))
    end
    return parse_primary!(parser, source)
end

function parse_primary!(parser::FormulaParser, source::AbstractString)
    tok = peek_token(parser)
    if tok.kind === :number
        advance_token!(parser)
        return FormulaNumber(parse(Float64, tok.text))
    elseif tok.kind === :name
        advance_token!(parser)
        if peek_token(parser).kind === :lparen
            advance_token!(parser)
            args = FormulaExpr[]
            if peek_token(parser).kind !== :rparen
                push!(args, parse_expr!(parser, source))
                while peek_token(parser).kind === :comma
                    advance_token!(parser)
                    push!(args, parse_expr!(parser, source))
                end
            end
            peek_token(parser).kind === :rparen || throw(ArgumentError(
                "Missing `)` in unit conversion formula \"$source\"."))
            advance_token!(parser)
            return FormulaCall(Symbol(tok.text), args)
        end
        return FormulaVar(Symbol(tok.text))
    elseif tok.kind === :lparen
        advance_token!(parser)
        expr = parse_expr!(parser, source)
        peek_token(parser).kind === :rparen || throw(ArgumentError(
            "Missing `)` in unit conversion formula \"$source\"."))
        advance_token!(parser)
        return expr
    elseif tok.kind === :eof
        throw(ArgumentError("Unexpected end of unit conversion formula \"$source\"."))
    else
        throw(ArgumentError("Unexpected `$(tok.text)` in unit conversion formula \"$source\"."))
    end
end

is_converted_param(name::Symbol, variable::Symbol) = name === variable || name === :x

function validate_formula(expr::FormulaExpr, variable::Symbol,
                          constants::AbstractDict{Symbol, <:Real},
                          unavailable, ambiguous)
    uses_raw = Ref(false)
    uses_log10 = Ref(false)
    function visit(node::FormulaExpr)
        if node isa FormulaNumber
            return nothing
        elseif node isa FormulaVar
            name = node.name
            if is_converted_param(name, variable)
                uses_raw[] = true
            elseif name in ambiguous
                throw(ArgumentError(
                    "`$name` is ambiguous: it is both a rig constant and a stimulus parameter."))
            elseif name in unavailable
                throw(ArgumentError(
                    "`$name` has no single value (it is an independent variable or adjusted by " *
                    "the method)."))
            elseif !haskey(constants, name)
                throw(ArgumentError("Unknown name `$name` in unit conversion formula."))
            end
        elseif node isa FormulaUnary
            visit(node.arg)
        elseif node isa FormulaBinary
            visit(node.left)
            visit(node.right)
        elseif node isa FormulaCall
            if node.func !== :log10
                throw(ArgumentError(
                    "Unknown function `$(node.func)` in unit conversion formula; only " *
                    "`log10` is allowed."))
            end
            if length(node.args) != 1 || !(node.args[1] isa FormulaVar) ||
               !is_converted_param(node.args[1].name, variable)
                arg_desc = length(node.args) == 1 && node.args[1] isa FormulaVar ?
                    "`$(node.args[1].name)`" : "that expression"
                throw(ArgumentError(
                    "`log10` can only be applied to `$variable` (or `x`), not $arg_desc."))
            end
            uses_log10[] = true
        end
        return nothing
    end
    visit(expr)
    uses_raw[] && uses_log10[] && throw(ArgumentError(
        "Parameter `$variable` cannot appear both inside and outside `log10`."))
    !uses_raw[] && !uses_log10[] && throw(ArgumentError(
        "Formula does not depend on `$variable`."))
    return uses_log10[] ? :log10 : :affine
end

function eval_formula(expr::FormulaExpr, variable::Symbol,
                      constants::AbstractDict{Symbol, <:Real}, u::Float64)::Float64
    if expr isa FormulaNumber
        return expr.value
    elseif expr isa FormulaVar
        return is_converted_param(expr.name, variable) ? u : Float64(constants[expr.name])
    elseif expr isa FormulaUnary
        val = eval_formula(expr.arg, variable, constants, u)
        return expr.op === :- ? -val : val
    elseif expr isa FormulaBinary
        a = eval_formula(expr.left, variable, constants, u)
        b = eval_formula(expr.right, variable, constants, u)
        expr.op === :+ && return a + b
        expr.op === :- && return a - b
        expr.op === :* && return a * b
        return a / b
    elseif expr isa FormulaCall
        # Validated above to be log10 of the converted parameter, whose value is u
        return u
    end
    error("Unreachable FormulaExpr: $(typeof(expr))")
end

function parse_unit_formula(variable::Symbol, label::AbstractString, formula::AbstractString;
                            constants::AbstractDict{Symbol, <:Real} = Dict{Symbol, Float64}(),
                            unavailable = Symbol[],
                            ambiguous = Symbol[])
    label = strip(label)
    isempty(label) &&
        throw(ArgumentError("A unit conversion needs a label to show its values under."))
    formula = strip(formula)
    isempty(formula) && throw(ArgumentError(
        "Expected a conversion formula after `=` for `$variable`."))
    expr = parse_formula(formula)
    form = validate_formula(expr, variable, constants, unavailable, ambiguous)
    y1 = eval_formula(expr, variable, constants, 1.0)
    y2 = eval_formula(expr, variable, constants, 2.0)
    y3 = eval_formula(expr, variable, constants, 7.31)
    if !(isfinite(y1) && isfinite(y2) && isfinite(y3))
        throw(ArgumentError(
            "Formula \"$formula\" is not linear in `$variable` (produces a non-finite value)."))
    end
    scale = y2 - y1
    offset = y1 - scale
    if !(isfinite(scale) && isfinite(offset)) ||
       !isapprox(y3, scale * 7.31 + offset; rtol = 1e-9, atol = 1e-12)
        throw(ArgumentError(
            "Formula \"$formula\" is not linear in " *
            (form === :log10 ? "`log10($variable)`." : "`$variable`.")))
    end
    scale == 0 && throw(ArgumentError(
        "Formula \"$formula\" does not depend on `$variable` (zero scale)."))
    offset == 0 && (offset = 0.0)
    return UnitConversion(label, form, scale, offset, formula)
end

"""
    parse_unit_conversion(variable, text; constants = Dict(), unavailable = Symbol[],
                          ambiguous = Symbol[]) -> Union{Nothing, UnitConversion}

Parses a unit conversion entry: empty text removes the conversion (`nothing`),
`"<label>"` alone gives an identity conversion with no formula, and
`"<label> = <formula>"` (split at the last `=`) resolves a linear formula in `variable`
(or `x`, or `log10` of it) over `constants`. Unknown, `unavailable`, or `ambiguous`
names, unsupported functions, and non-linear formulas throw an `ArgumentError`.
"""
function parse_unit_conversion(variable::Symbol, text::AbstractString;
                               constants::AbstractDict{Symbol, <:Real} = Dict{Symbol, Float64}(),
                               unavailable = Symbol[],
                               ambiguous = Symbol[])
    text = strip(text)
    isempty(text) && return nothing
    position = findlast('=', text)
    position === nothing && return UnitConversion(text)
    label = position == firstindex(text) ? "" : strip(text[1:prevind(text, position)])
    formula = position == lastindex(text) ? "" : strip(text[nextind(text, position):end])
    return parse_unit_formula(variable, label, formula; constants, unavailable, ambiguous)
end

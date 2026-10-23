# Date and time values (https://www.w3.org/TR/exi/#encodingDateTime).
#
# A value is a sequence of parts; which parts appear depends on the kind
# (Table 7-4 of the spec):
#
# | part           | layout                                   | kinds                    |
# |----------------|------------------------------------------|--------------------------|
# | Year           | Integer, year - 2000                     | dateTime date gYear gYearMonth |
# | MonthDay       | 9 bits, month * 32 + day                 | all but gYear and time   |
# | Time           | 17 bits, (hour * 64 + minute) * 64 + second | dateTime time         |
# | FractionalSecs | presence bit, then unsigned (digits reversed) | dateTime time       |
# | TimeZone       | presence bit, then 11 bits, hours * 64 + minutes + 896 | all     |

const YEAR_OFFSET = 2000
const TIMEZONE_OFFSET = 896
const BITS_MONTH_DAY = 9
const BITS_TIME = 17
const BITS_TIMEZONE = 11
const MAX_TIMEZONE_MINUTES = 14 * 60

has_year(k::DateTimeKind) = k == DTK_DATETIME || k == DTK_DATE || k == DTK_GYEAR || k == DTK_GYEARMONTH
has_month_day(k::DateTimeKind) = !(k == DTK_GYEAR || k == DTK_TIME)
has_month(k::DateTimeKind) = !(k == DTK_GYEAR || k == DTK_TIME || k == DTK_GDAY)
has_day(k::DateTimeKind) = k == DTK_DATETIME || k == DTK_DATE || k == DTK_GMONTHDAY || k == DTK_GDAY
has_time(k::DateTimeKind) = k == DTK_DATETIME || k == DTK_TIME

const DATETIME_KIND_NAMES = ("dateTime", "date", "time", "gYear", "gYearMonth", "gMonth", "gMonthDay", "gDay")
datetime_kind_name(k::DateTimeKind) = DATETIME_KIND_NAMES[Int(k) + 1]

"""
    check_datetime(dt) -> Union{Nothing,String}

Checks the ranges of the fields the kind uses. Returns why it is out of range,
or `nothing` when it is fine.
"""
function check_datetime(dt::ExiDateTime)
    k = dt.kind
    has_month(k) && !(1 <= dt.month <= 12) && return "month $(dt.month) out of range"
    has_day(k) && !(1 <= dt.day <= 31) && return "day $(dt.day) out of range"
    if has_time(k)
        dt.hour > 24 && return "hour $(dt.hour) out of range"
        dt.minute > 59 && return "minute $(dt.minute) out of range"
        dt.second > 60 && return "second $(dt.second) out of range"
    end
    tz = dt.timezone
    if tz !== nothing && abs(Int(tz)) > MAX_TIMEZONE_MINUTES
        return "time zone offset $tz minutes out of range"
    end
    return nothing
end

function days_in_month(year::Int64, month::Integer)
    month in (1, 3, 5, 7, 8, 10, 12) && return 31
    month in (4, 6, 9, 11) && return 30
    if month == 2
        leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        return leap ? 29 : 28
    end
    return 31
end

"""
Turns hour 24 (allowed by XSD for midnight at the end of a day) into hour 0, of
the next day for a `dateTime`, as EXIficient does.
"""
function normalize_hour24(dt::ExiDateTime)
    (has_time(dt.kind) && dt.hour == 24) || return dt
    year, month, day = dt.year, Int(dt.month), Int(dt.day)
    if dt.kind == DTK_DATETIME
        day += 1
        if day > days_in_month(year, month)
            day = 1
            month += 1
            if month > 12
                month = 1
                year += 1
            end
        end
    end
    return ExiDateTime(dt.kind, year, UInt8(month), UInt8(day), 0x00, dt.minute, dt.second,
        dt.fractional_secs, dt.timezone)
end

# A small cursor over the text, for the parser below.
mutable struct DtCursor
    s::Vector{UInt8}
    pos::Int
end

dt_peek(c::DtCursor) = c.pos <= length(c.s) ? c.s[c.pos] : nothing

function expect!(c::DtCursor, ch::Char)
    dt_peek(c) == UInt8(ch) || return false
    c.pos += 1
    return true
end

digit_at(c::DtCursor, i::Int) =
    (i <= length(c.s) && UInt8('0') <= c.s[i] <= UInt8('9')) ? Int(c.s[i] - UInt8('0')) : nothing

function two_digits!(c::DtCursor)
    a = digit_at(c, c.pos)
    b = digit_at(c, c.pos + 1)
    (a === nothing || b === nothing) && return nothing
    c.pos += 2
    return 10a + b
end

function digits!(c::DtCursor)
    start = c.pos
    while digit_at(c, c.pos) !== nothing
        c.pos += 1
    end
    return String(c.s[start:(c.pos - 1)])
end

function year!(c::DtCursor)
    negative = expect!(c, '-')
    d = digits!(c)
    length(d) < 4 && return nothing
    v = tryparse(Int64, d)
    v === nothing && return nothing
    return negative ? -v : v
end

# Reads `hh:mm:ss[.fff]`; returns (hour, minute, second, fractional) or nothing.
function time!(c::DtCursor)
    h = two_digits!(c)
    h === nothing && return nothing
    expect!(c, ':') || return nothing
    m = two_digits!(c)
    m === nothing && return nothing
    expect!(c, ':') || return nothing
    s = two_digits!(c)
    s === nothing && return nothing
    frac = nothing
    if expect!(c, '.')
        d = digits!(c)
        isempty(d) && return nothing
        f = tryparse(UInt64, reverse(d))
        f === nothing && return nothing
        frac = f == 0 ? nothing : f
    end
    return (h, m, s, frac)
end

# Reads an optional time zone; returns `missing` when malformed, else the
# offset in minutes or nothing.
function timezone!(c::DtCursor)
    p = dt_peek(c)
    p === nothing && return nothing
    if p == UInt8('Z')
        c.pos += 1
        return Int16(0)
    end
    if p == UInt8('+') || p == UInt8('-')
        c.pos += 1
        h = two_digits!(c)
        h === nothing && return missing
        expect!(c, ':') || return missing
        m = two_digits!(c)
        (m === nothing || m > 59) && return missing
        total = Int16(60h + m)
        return p == UInt8('-') ? -total : total
    end
    return missing
end

"""
    datetime_from_lexical(kind, s) -> Union{Nothing,ExiDateTime}

Parses the XSD text form of a date/time type. The old `--MM--` form of gMonth
is accepted. Hour 24 is turned into hour 0 (see `normalize_hour24`).
"""
function datetime_from_lexical(kind::DateTimeKind, s::AbstractString)
    c = DtCursor(Vector{UInt8}(codeunits(s)), 1)
    year = 0
    month = 0
    day = 0
    hms = (0, 0, 0, nothing)
    if kind == DTK_GYEAR
        y = year!(c)
        y === nothing && return nothing
        year = y
    elseif kind == DTK_GYEARMONTH || kind == DTK_DATE || kind == DTK_DATETIME
        y = year!(c)
        y === nothing && return nothing
        year = y
        expect!(c, '-') || return nothing
        m = two_digits!(c)
        m === nothing && return nothing
        month = m
        if kind != DTK_GYEARMONTH
            expect!(c, '-') || return nothing
            d = two_digits!(c)
            d === nothing && return nothing
            day = d
        end
        if kind == DTK_DATETIME
            expect!(c, 'T') || return nothing
            t = time!(c)
            t === nothing && return nothing
            hms = t
        end
    elseif kind == DTK_TIME
        t = time!(c)
        t === nothing && return nothing
        hms = t
    elseif kind == DTK_GMONTH || kind == DTK_GMONTHDAY
        (expect!(c, '-') && expect!(c, '-')) || return nothing
        m = two_digits!(c)
        m === nothing && return nothing
        month = m
        if kind == DTK_GMONTH
            # Old gMonth form `--MM--`: skip the trailing `--` if present.
            if c.pos + 1 <= length(c.s) && c.s[c.pos] == UInt8('-') && c.s[c.pos + 1] == UInt8('-')
                c.pos += 2
            end
        else
            expect!(c, '-') || return nothing
            d = two_digits!(c)
            d === nothing && return nothing
            day = d
        end
    else # DTK_GDAY
        (expect!(c, '-') && expect!(c, '-') && expect!(c, '-')) || return nothing
        d = two_digits!(c)
        d === nothing && return nothing
        day = d
    end
    tz = timezone!(c)
    tz === missing && return nothing
    c.pos == length(c.s) + 1 || return nothing
    dt = ExiDateTime(kind; year, month, day, hour = hms[1], minute = hms[2], second = hms[3],
        fractional_secs = hms[4], timezone = tz)
    check_datetime(dt) === nothing || return nothing
    return normalize_hour24(dt)
end

two(v::Integer) = lpad(string(v), 2, '0')

function push_year!(io::IO, year::Int64)
    year < 0 && print(io, '-')
    print(io, lpad(string(abs(Int128(year))), 4, '0'))
end

function push_time!(io::IO, dt::ExiDateTime)
    print(io, two(dt.hour), ':', two(dt.minute), ':', two(dt.second))
    f = dt.fractional_secs
    if f !== nothing && f != 0
        print(io, '.', reverse(string(f)))
    end
end

"""The standard text form of a date/time value (time zone `+00:00` is `Z`)."""
function datetime_to_lexical(dt::ExiDateTime)
    io = IOBuffer()
    k = dt.kind
    if k == DTK_GYEAR
        push_year!(io, dt.year)
    elseif k == DTK_GYEARMONTH
        push_year!(io, dt.year)
        print(io, '-', two(dt.month))
    elseif k == DTK_DATE || k == DTK_DATETIME
        push_year!(io, dt.year)
        print(io, '-', two(dt.month), '-', two(dt.day))
        if k == DTK_DATETIME
            print(io, 'T')
            push_time!(io, dt)
        end
    elseif k == DTK_TIME
        push_time!(io, dt)
    elseif k == DTK_GMONTH
        print(io, "--", two(dt.month))
    elseif k == DTK_GMONTHDAY
        print(io, "--", two(dt.month), '-', two(dt.day))
    else
        print(io, "---", two(dt.day))
    end
    tz = dt.timezone
    if tz !== nothing
        if tz == 0
            print(io, 'Z')
        else
            mag = abs(Int(tz))
            print(io, tz < 0 ? '-' : '+', two(mag ÷ 60), ':', two(mag % 60))
        end
    end
    return String(take!(io))
end

function month_day(dt::ExiDateTime)
    k = dt.kind
    (k == DTK_GYEARMONTH || k == DTK_GMONTH) && return UInt64(dt.month) * 32
    k == DTK_GDAY && return UInt64(dt.day)
    return UInt64(dt.month) * 32 + UInt64(dt.day)
end

function timezone_to_wire(tz::Int16)
    mag = abs(Int(tz))
    base64 = (mag ÷ 60) * 64 + mag % 60
    return UInt64((tz < 0 ? -base64 : base64) + TIMEZONE_OFFSET)
end

function timezone_from_wire(wire::UInt64)
    signed = Int(wire) - TIMEZONE_OFFSET
    mag = abs(signed)
    minutes = (mag ÷ 64) * 60 + mag % 64
    return Int16(signed < 0 ? -minutes : minutes)
end

"""
    write_datetime!(w, dt)

Writes a date/time value. It checks the ranges first and turns hour 24 into
hour 0, as EXIficient's constructor does.
"""
function write_datetime!(w::BitWriter, value::ExiDateTime)
    why = check_datetime(value)
    why === nothing || throw(ValueError("Date-Time", why))
    dt = normalize_hour24(value)
    k = dt.kind
    if has_year(k)
        dt.year < typemin(Int64) + YEAR_OFFSET && throw(ValueError("Date-Time", "year out of range"))
        write_integer!(w, dt.year - YEAR_OFFSET)
    end
    has_month_day(k) && write_nbit_unsigned!(w, month_day(dt), BITS_MONTH_DAY)
    if has_time(k)
        t = (UInt64(dt.hour) * 64 + UInt64(dt.minute)) * 64 + UInt64(dt.second)
        write_nbit_unsigned!(w, t, BITS_TIME)
        f = dt.fractional_secs
        if f !== nothing && f != 0
            write_bool!(w, true)
            write_unsigned!(w, f)
        else
            write_bool!(w, false)
        end
    end
    tz = dt.timezone
    if tz !== nothing
        write_bool!(w, true)
        write_nbit_unsigned!(w, timezone_to_wire(tz), BITS_TIMEZONE)
    else
        write_bool!(w, false)
    end
    return w
end

"""Reads a date/time value of `kind`, checking its ranges like the encoder."""
function read_datetime!(r::BitReader, kind::DateTimeKind, max_bits::Int = typemax(Int))
    year = Int64(0)
    month = 0x00
    day = 0x00
    hour = minute = second = 0x00
    frac = nothing
    if has_year(kind)
        y = read_integer!(r, max_bits)
        y isa Int64 || throw(ValueError("Date-Time", "year out of range"))
        y64::Int64 = y
        y64 <= typemax(Int64) - YEAR_OFFSET || throw(ValueError("Date-Time", "year out of range"))
        year = y64 + YEAR_OFFSET
    end
    if has_month_day(kind)
        md = read_nbit_unsigned!(r, BITS_MONTH_DAY)
        month = UInt8(md ÷ 32)
        day = UInt8(md % 32)
    end
    if has_time(kind)
        t = read_nbit_unsigned!(r, BITS_TIME)
        hour = UInt8(t ÷ (64 * 64))
        minute = UInt8((t ÷ 64) % 64)
        second = UInt8(t % 64)
        if read_bool!(r)
            f = read_unsigned!(r)
            frac = f == 0 ? nothing : f
        end
    end
    tz = read_bool!(r) ? timezone_from_wire(read_nbit_unsigned!(r, BITS_TIMEZONE)) : nothing
    dt = ExiDateTime(kind, year, month, day, hour, minute, second, frac, tz)
    why = check_datetime(dt)
    why === nothing || throw(ValueError("Date-Time", why))
    return normalize_hour24(dt)
end

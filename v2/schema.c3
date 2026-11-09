// v2: core schema helpers. Card (b) owns this file; cards (c) and (d) call these signatures.
// The bodies are the old builder.c3 code, moved verbatim.
module yaml2;

const String TAG_STR = "tag:yaml.org,2002:str";
const String TAG_NULL = "tag:yaml.org,2002:null";
const String TAG_BOOL = "tag:yaml.org,2002:bool";
const String TAG_INT = "tag:yaml.org,2002:int";
const String TAG_FLOAT = "tag:yaml.org,2002:float";

fn bool is_null_text(String v) => v == "" || v == "~" || v == "null" || v == "Null" || v == "NULL";
fn bool is_bool_text(String v) => v == "true" || v == "True" || v == "TRUE" || v == "false" || v == "False" || v == "FALSE";

// Number of characters from `*i` on that are digits in `base`; advances `*i`.
fn sz digits(String v, sz* i, int base = 10)
{
	sz from = *i;
	while (*i < v.len && (base == 16 ? v[*i].is_xdigit() : v[*i] >= '0' && v[*i] < '0' + base)) (*i)++;
	return *i - from;
}

// [-+]?[0-9]+ | 0o[0-7]+ | 0x[0-9a-fA-F]+; NOT_FOUND if `v` does not match, a fault from
// to_int128 if it does not fit.
fn int128? int_of(String v)
{
	int base = v.starts_with("0o") ? 8 : v.starts_with("0x") ? 16 : 10;
	sz from = base == 10 ? 0 : 2;
	sz i = from;
	if (base == 10 && v.len && (v[0] == '-' || v[0] == '+')) i++;
	if (!digits(v, &i, base) || i != v.len) return NOT_FOUND~;
	return v[from..].to_int128(base);
}

// [-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)? | [-+]?\.(inf|Inf|INF) | \.(nan|NaN|NAN);
// NOT_FOUND if `v` does not match. Out of range is ±inf.
fn double? float_of(String v)
{
	bool minus = v.len && v[0] == '-';
	sz i = v.len && (minus || v[0] == '+') ? 1 : 0;
	String unsigned = v[i..];
	if (unsigned == ".inf" || unsigned == ".Inf" || unsigned == ".INF") return minus ? -double::inf : double::inf;
	if (v == ".nan" || v == ".NaN" || v == ".NAN") return double::nan;
	sz whole = digits(v, &i);
	if (i < v.len && v[i] == '.')
	{
		i++;
		if (!digits(v, &i) && !whole) return NOT_FOUND~;
	}
	else if (!whole)
	{
		return NOT_FOUND~;
	}
	if (i < v.len && (v[i] == 'e' || v[i] == 'E'))
	{
		i++;
		if (i < v.len && (v[i] == '-' || v[i] == '+')) i++;
		if (!digits(v, &i)) return NOT_FOUND~;
	}
	if (i != v.len) return NOT_FOUND~;
	double? d = v.to_double();
	if (catch d) return minus ? -double::inf : double::inf;   // only the range can fail here
	return d;
}

/// Builds the PostgREST `or=(...)` filter for the lead search box without letting the typed text
/// change the query's structure.
///
/// The term is typed by a person, so it may contain `,` `(` `)` `.` `"` or `\`, any of which
/// would otherwise end the value early and let the rest be parsed as extra predicates
/// (`a),email.eq.x` adds a clause). Each value is therefore sent as a PostgREST double-quoted
/// string, in which only `"` and `\` need escaping, and the `LIKE` metacharacters (`%`, `_`,
/// and the escape character `\`) are escaped first so the term matches literally.
///
/// Remaining caveat: PostgREST itself treats an unescaped `*` in a `like`/`ilike` value as `%`.
/// That can only broaden a search within rows the caller's RLS already allows.
const List<String> kCrmLeadSearchColumns = [
  'full_name',
  'company',
  'email',
  'phone',
];

/// Escapes [term] for use as a literal substring inside a `LIKE`/`ILIKE` pattern.
String escapeLikeLiteral(String term) =>
    term.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');

/// Wraps [value] as a PostgREST double-quoted filter value.
String quotePostgrestValue(String value) {
  final escaped = value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  return '"$escaped"';
}

/// The argument for `PostgrestFilterBuilder.or(...)` matching [term] as a substring of any of
/// [kCrmLeadSearchColumns]. [term] must already be trimmed and non-empty.
String crmLeadSearchFilter(String term) {
  final pattern = quotePostgrestValue('%${escapeLikeLiteral(term)}%');
  return [
    for (final column in kCrmLeadSearchColumns) '$column.ilike.$pattern',
  ].join(',');
}

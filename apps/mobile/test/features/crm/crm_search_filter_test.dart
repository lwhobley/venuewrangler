import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/crm/data/crm_search_filter.dart';

/// Splits a generated filter the way PostgREST does at the top level: on commas that are
/// outside double-quoted strings, honouring backslash escapes inside them.
List<String> _topLevelClauses(String filter) {
  final clauses = <String>[];
  final current = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < filter.length; i++) {
    final c = filter[i];
    if (inQuotes && c == r'\') {
      current
        ..write(c)
        ..write(filter[++i]);
      continue;
    }
    if (c == '"') inQuotes = !inQuotes;
    if (c == ',' && !inQuotes) {
      clauses.add(current.toString());
      current.clear();
      continue;
    }
    current.write(c);
  }
  clauses.add(current.toString());
  return clauses;
}

void main() {
  const columns = ['full_name', 'company', 'email', 'phone'];

  test('a plain term becomes one quoted ilike per column', () {
    expect(
      crmLeadSearchFilter('smith'),
      'full_name.ilike."%smith%",company.ilike."%smith%",'
      'email.ilike."%smith%",phone.ilike."%smith%"',
    );
  });

  test('a comma in the term does not split the clause', () {
    final filter = crmLeadSearchFilter('Smith, Inc');

    expect(filter, contains('full_name.ilike."%Smith, Inc%"'));
    expect(_topLevelClauses(filter), hasLength(4));
  });

  test('an injection attempt stays inside the quoted value', () {
    final filter = crmLeadSearchFilter('a),email.eq.x');

    expect(filter, contains('full_name.ilike."%a),email.eq.x%"'));
    final clauses = _topLevelClauses(filter);
    expect(clauses, hasLength(4));
    for (var i = 0; i < clauses.length; i++) {
      expect(clauses[i], '${columns[i]}.ilike."%a),email.eq.x%"');
    }
  });

  test('double quotes are backslash-escaped', () {
    final filter = crmLeadSearchFilter('say "hi"');

    expect(filter, contains(r'full_name.ilike."%say \"hi\"%"'));
    expect(_topLevelClauses(filter), hasLength(4));
  });

  test('a quote followed by an injected clause cannot close the string', () {
    final filter = crmLeadSearchFilter('x",email.eq.y,"');

    expect(filter, contains(r'"%x\",email.eq.y,\"%"'));
    expect(_topLevelClauses(filter), hasLength(4));
  });

  test('backslashes are doubled for LIKE and again for PostgREST', () {
    // One literal backslash needs `\\` for LIKE, and each of those two must itself be
    // doubled inside the PostgREST quoted string: four in total.
    expect(
      crmLeadSearchFilter(r'a\b'),
      contains(r'full_name.ilike."%a\\\\b%"'),
    );
    // A trailing backslash must not escape the closing quote.
    final filter = crmLeadSearchFilter(r'end\');
    expect(filter, contains(r'full_name.ilike."%end\\\\%"'));
    expect(_topLevelClauses(filter), hasLength(4));
  });

  test('LIKE wildcards match literally', () {
    expect(
      crmLeadSearchFilter('100%_off'),
      contains(r'full_name.ilike."%100\\%\\_off%"'),
    );
  });

  test('parentheses and dots are plain text', () {
    final filter = crmLeadSearchFilter('(a.b)');

    expect(filter, contains('full_name.ilike."%(a.b)%"'));
    expect(_topLevelClauses(filter), hasLength(4));
  });

  test('escape helpers', () {
    expect(escapeLikeLiteral(r'50%_\'), r'50\%\_\\');
    expect(quotePostgrestValue(r'a"b\c'), r'"a\"b\\c"');
  });
}

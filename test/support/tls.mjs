export function validateTls(report) {
  const errors = [];
  if (!report?.complete || !report.passed ||
      report.expectedObservations !== 4 || report.observations !== 4 ||
      !Array.isArray(report.results) || report.results.length !== 4 ||
      report.results.some(row => row.tests.length !== 3 ||
        row.tests.some(test => !test.executed || !test.passed)))
    errors.push('Incomplete trusted/rejected TLS matrix');
  return errors;
}

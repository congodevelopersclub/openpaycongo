import { readFile } from 'node:fs/promises';

const fixtureDirectory = new URL('../docs/', import.meta.url);

export async function loadCanonicalAnalyticsFixtures() {
  const [vector, response] = await Promise.all([
    readFile(new URL('sales-analytics.vector.json', fixtureDirectory), 'utf8'),
    readFile(new URL('sales-analytics-response.valid.json', fixtureDirectory), 'utf8'),
  ]);

  return {
    vector: JSON.parse(vector),
    response: JSON.parse(response),
  };
}

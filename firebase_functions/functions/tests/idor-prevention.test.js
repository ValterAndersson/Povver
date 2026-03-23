const { test, describe } = require('node:test');
const assert = require('node:assert/strict');

const IDOR_FIXED_FILES = [
  '../routines/create-routine',
  '../routines/update-routine',
  '../routines/delete-routine',
  '../routines/set-active-routine',
  '../templates/create-template',
  '../templates/update-template',
  '../templates/delete-template',
  '../user/update-user',
];

describe('IDOR prevention: all flexible-auth endpoints use getAuthenticatedUserId', () => {
  const fs = require('fs');
  const path = require('path');

  for (const modPath of IDOR_FIXED_FILES) {
    const fileName = modPath.split('/').pop();
    test(`${fileName} imports getAuthenticatedUserId`, () => {
      const filePath = path.resolve(__dirname, modPath + '.js');
      const source = fs.readFileSync(filePath, 'utf-8');
      assert.ok(
        source.includes("getAuthenticatedUserId"),
        `${fileName}.js must import and use getAuthenticatedUserId`
      );
      const bodyUserIdPattern = /const\s*\{[^}]*userId[^}]*\}\s*=\s*req\.body/;
      assert.ok(
        !bodyUserIdPattern.test(source),
        `${fileName}.js must NOT destructure userId from req.body`
      );
    });
  }
});

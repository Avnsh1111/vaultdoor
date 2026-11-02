// Runs in the real window after the Keychain refused the key once.
const out = {};
const check = (name, value, detail) => { out[name] = value ? true : (detail === undefined ? false : detail); };
const wait = ms => new Promise(r => setTimeout(r, ms));
const stage = document.getElementById('stage');
check('the page says the vault could not open', stage.innerText.includes('could not open'), stage.innerText.slice(0, 120));
check('the header is still there', document.querySelector('header').innerText.includes('Settings'));
check('it offers a retry', !!document.querySelector('[data-retry]'));
const again = await call('state');
check('other requests report the error without a new prompt', !!again.error, again);
document.querySelector('[data-retry]').dispatchEvent(new MouseEvent('click', { bubbles: true }));
for (let i = 0; i < 40 && !booted; i++) await wait(100);
check('trying again opens the vault', booted === true);
check('the project appears', stage.innerText.includes('waitproj'));
return JSON.stringify(out);

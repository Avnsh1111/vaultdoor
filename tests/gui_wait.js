// Runs in the real window while the vault's key takes 6 seconds to arrive, as it
// does when a Keychain prompt is open. The window must stay alive and explain why.
const out = {};
const check = (name, value, detail) => { out[name] = value ? true : (detail === undefined ? false : detail); };
const wait = ms => new Promise(r => setTimeout(r, ms));
check('the header is on screen straight away', document.querySelector('header').innerText.includes('Vault door'));
check('the lock button is drawn', document.getElementById('lock').innerText.includes('Locked'), document.getElementById('lock').innerText);
check('the page explains the wait', document.getElementById('stage').innerText.includes('Waiting for macOS'), document.getElementById('stage').innerText.slice(0, 120));
check('nothing is drawn as loaded yet', booted === false);
const started = performance.now();
const reply = await call('activity');
const took = Math.round(performance.now() - started);
check('the app answers while the key is pending', Array.isArray(reply.activity) && took < 500, took);
const moved = await call('generatorStatus');
check('background checks keep working', moved.active === false, moved);
for (let i = 0; i < 60 && !booted; i++) await wait(200);
check('the page finishes once the key arrives', booted === true);
check('the project appears', document.getElementById('stage').innerText.includes('waitproj'));
return JSON.stringify(out);

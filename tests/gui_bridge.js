// Runs inside the real dashboard window in the test build. Clicks real buttons,
// so each request crosses the real bridge into the real app.
const out = {};
const check = (name, value, detail) => { out[name] = value ? true : (detail === undefined ? false : detail); };
const wait = ms => new Promise(r => setTimeout(r, ms));
const $ = s => document.querySelector(s);
const click = async (selector, ms = 400) => {
  const el = typeof selector === 'string' ? $(selector) : selector;
  if (!el) throw new Error('nothing to click: ' + selector);
  el.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  await wait(ms);
};
const SECRET = 'typed-Canary-Secret-77';
const noLeak = () => !document.documentElement.outerHTML.includes(SECRET) && !JSON.stringify(S).includes(SECRET);
try {
  const project = () => S.projects.find(p => p.id === 'w1');
  check('the page opens the project', cur === 'w1', cur);

  // Add a server: the form, then the native box answered by the test build.
  await click('[data-add="server"]');
  check('the add server form opens', !!$('#f-sname'));
  $('#f-sname').value = 'Staging'; $('#f-host').value = 'staging.test'; $('#f-user').value = 'deploy'; $('#f-port').value = '2204'; $('#f-auth').value = 'password';
  await click('[data-do="saveServer"]', 700);
  const staging = S.servers.find(s => s.name === 'Staging');
  check('add server saves it', staging && staging.host === 'staging.test' && staging.port === 2204 && staging.hasLogin, staging);
  check('the mapping form opens next', !!$('#f-path'));
  check('the typed login never reaches the page', noLeak());

  // Map it with a folder, using the variable names from the prefix.
  $('#f-path').value = '/srv/staging';
  $('#f-label').value = 'staging';
  const prefix = $('#f-prefix');
  prefix.value = 'STAGE';
  prefix.dispatchEvent(new Event('change', { bubbles: true }));
  await wait(300);
  check('the prefix fills in variable names', [...document.querySelectorAll('[data-var="path"]')].some(e => e.value === 'STAGE_PATH'), [...document.querySelectorAll('[data-var]')].map(e => e.dataset.var + '=' + e.value));
  await click('[data-do="saveLink"]', 600);
  let link = project().links.find(l => l.label === 'staging');
  check('mapping saves the folder', link && link.path === '/srv/staging' && link.env.path === 'STAGE_PATH', link);
  check('the mapping shows on the main screen', L[cur].has(staging.id));

  // Edit, then remove, through its hexagon.
  await click(`[data-r="${staging.id}"]`);
  check('clicking a mapped server shows its folder', $('#f-path') && $('#f-path').value === '/srv/staging', $('#f-path') && $('#f-path').value);
  await click('[data-do="closeModal"]', 150);

  // A bad folder is refused with a message.
  await click(`[data-r="${staging.id}"]`);
  $('#f-path').value = 'relative/path';
  await click('[data-do="saveLink"]', 500);
  check('a relative folder is refused', project().links.find(l => l.label === 'staging').path === '/srv/staging' && $('#toast').textContent.includes('full path'), $('#toast').textContent);
  await click('[data-do="closeModal"]', 150);

  await click(`[data-r="${staging.id}"]`);
  await click('#modal [data-do="removeLink"]', 500);
  check('removing the mapping works', !project().links.some(l => l.label === 'staging'));

  // Keys and apps.
  await click('[data-add="key"]');
  $('#f-name').value = 'Stripe'; $('#f-env').value = 'STRIPE_TOKEN';
  const kind = $('#f-kind'); kind.value = 'token'; kind.dispatchEvent(new Event('change', { bubbles: true }));
  await wait(150);
  check('switching the key type keeps what was typed', $('#f-name').value === 'Stripe' && !!$('#f-hosts'));
  $('#f-hosts').value = 'api.stripe.com';
  await click('[data-do="saveKey"]', 600);
  const stripe = S.keys.find(k => k.name === 'Stripe');
  check('add key saves it and turns it on', stripe && project().keyIDs.includes(stripe.id) && stripe.allowedHosts[0] === 'api.stripe.com', stripe);
  await click(`[data-r="${stripe.id}"]`, 500);
  check('clicking a key turns it off', !project().keyIDs.includes(stripe.id));
  await click(`[data-r="${stripe.id}"]`, 500);
  check('clicking again turns it back on', project().keyIDs.includes(stripe.id));
  await click('[data-r="slack_app"]', 500);
  check('clicking an app switches it off', project().disabledApps.includes('slack_app'), project().disabledApps);
  check('typed secrets stay out of the page', noLeak());

  // Every view draws the real data, and a server hexagon works from each.
  for (const v of ['map', 'orbit', 'wall', 'vault']) {
    await click(`#seg button[data-v="${v}"]`, 250);
    const hex = document.querySelector(`[data-r="${staging.id}"]`);
    check(v + ' view shows servers and keys', !!hex && !!document.querySelector(`[data-r="${stripe.id}"]`) && !!document.querySelector('[data-add="server"]') === (v !== 'orbit'));
    if (hex) {
      await click(hex, 250);
      check(v + ' view opens a server\'s folder form', !!$('#f-path'));
      await click('[data-do="closeModal"]', 120);
    }
  }

  // Settings.
  await click('#settings', 300);
  check('settings opens on servers', $('#dtabs .on').textContent === 'Servers' && $('#dbody').innerText.includes('Staging'));
  await click('[data-do="editServer"]', 200);
  $('#f-sname').value = 'Staging renamed';
  await click('[data-do="saveServerEdit"]', 500);
  check('editing a server saves it', S.servers.some(s => s.name === 'Staging renamed'));
  await click('[data-do="replaceLogin"]', 500);
  check('replacing a login keeps the page clean', noLeak());
  await click('[data-tab="actions"]', 100);
  check('the actions tab has the auto deploy button', !!$('[data-do="autoDeploy"]'));

  // Move .deploy, real file, real scan.
  await click('[data-do="scanDeploy"]', 500);
  const scanText = $('#modal').innerText;
  check('the import screen finds the server', scanText.includes('root@10.0.0.8') && scanText.includes('/var/www/win'), scanText.slice(0, 200));
  check('the import screen finds the other secret', scanText.includes('DB_OWNER_PASSWORD'));
  check('the import screen shows no secret value', !scanText.includes('win-Canary') && !document.documentElement.outerHTML.includes('win-Canary'));
  await click('[data-do="moveDeploy"]', 900);
  link = project().links.find(l => l.label === 'main');
  check('moving creates the server mapping', link && link.path === '/var/www/win' && link.env.password === 'DEPLOY_SSH_PASSWORD', project().links);
  check('moving creates the deploy action', project().actions.some(a => a.name === 'deploy'), project().actions);
  check('moved values stay out of the page', !JSON.stringify(S).includes('win-Canary'));
  await click('[data-do="closeDrawer"]', 300);

  // Auto deploy: the button, the live run, the review, the approval.
  await click('#auto', 500);
  check('the auto deploy button opens its form', !!$('#f-spath') && !!$('#f-notes'), $('#modal').innerText.slice(0, 120));
  check('it keeps the existing deploy script safe', $('#f-spath').value === 'scripts/deploy-auto.sh', $('#f-spath').value);
  check('it lists the mapped server', $('#modal').innerText.includes('root@10.0.0.8'));
  await click('[data-do="copyPrompt"]', 300);
  check('copy prompt works', $('#toast').textContent.includes('Prompt copied'), $('#toast').textContent);
  $('#f-notes').value = 'run migrations';
  await click('[data-do="generate"]', 200);
  for (let i = 0; i < 40 && !$('[data-do="approveGen"]'); i++) await wait(300);
  check('the run reaches the review screen', !!$('[data-do="approveGen"]'), $('#modal').innerText.slice(0, 200));
  const review = $('#modal').innerText;
  check('the review shows the script', review.includes('git pull'));
  check('the review shows the AI\'s notes', review.includes('Assumed git on the server'));
  check('the review offers a free action name', $('#f-gname').value === 'deploy-auto', $('#f-gname').value);
  check('the button shows it is ready', $('#auto').textContent.includes('Review script'), $('#auto').textContent);
  check('nothing was approved before review', !project().actions.some(a => a.script === 'scripts/deploy-auto.sh'));
  await click('[data-do="approveGen"]', 700);
  const action = project().actions.find(a => a.name === 'deploy-auto');
  check('approving creates the action', action && action.script === 'scripts/deploy-auto.sh' && action.changed.length === 0, project().actions);
  check('the button goes back to normal', $('#auto').textContent.includes('Auto deploy'), $('#auto').textContent);
  check('nothing typed reached the page', noLeak());
} catch (e) {
  out['the page script crashed: ' + e.message] = String(e.stack || e).slice(0, 300);
}
return JSON.stringify(out);

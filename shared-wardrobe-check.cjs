const {spawnSync}=require('node:child_process');
for(const key of ['CB_PGLITE_PATH','CB_PLAYWRIGHT_PATH'])if(!process.env[key]){console.error('Set '+key+' before running the wardrobe validation.');process.exit(1);}
const run=spawnSync(process.execPath,['--test','--test-concurrency=2','shared-wardrobe.sql.test.cjs','shared-wardrobe.ui.test.cjs','shared-shopping.sql.test.cjs','shared-shopping.ui.test.cjs','commerce.test.cjs'],{stdio:'inherit'});process.exit(run.status??1);

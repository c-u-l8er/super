// What a review test profile runs, and what a recorded run of it ran (T36). A record is described by what it records
// (its `tests`), so a run from before T36 widened the Rust and Elixir profiles is described as what it was, not as what
// those profiles run now. No DOM here, so the description can be tested on its own.
export const PROFILE_LABELS={'super-javascript-behavior@1':'JavaScript behavior tests','super-elixir-review@1':'Elixir: the whole ampd suite','super-rust-review@1':'Rust: host and cockpit suites','repository-document-review@1':'Repository document checks','repository-python-gate@1':'Repository gate checks'};
export const profileLabelFor=value=>PROFILE_LABELS[value]??PROFILE_LABELS['super-javascript-behavior@1'];
const ranBeforeT36=result=>{const t=Array.isArray(result?.tests)?result.tests:[];return result?.profile==='super-rust-review@1'?t.includes('tools/native-review/Cargo.toml'):result?.profile==='super-elixir-review@1'?t.includes('ampd/test/development_task_test.exs'):false;};
export function recordDescription(result){
  const n=Array.isArray(result?.tests)?result.tests.length:0,many=(k,s)=>k+' '+s+(k===1?'':'s');
  switch(result?.profile){
    case 'super-rust-review@1':return ranBeforeT36(result)?{label:'Rust (native review target, before T36)',detail:'Native review target',toolchain:'Rust toolchain and cached dependencies: '}:{label:PROFILE_LABELS['super-rust-review@1'],detail:'Host and cockpit suites',toolchain:'Rust toolchain, cached dependencies and RRABBIT: '};
    case 'super-elixir-review@1':return ranBeforeT36(result)?{label:'Elixir (two development_* files, before T36)',detail:'Two development_* test files',toolchain:'Elixir / Erlang toolchain: '}:{label:PROFILE_LABELS['super-elixir-review@1'],detail:'super-host build and the whole ampd suite',toolchain:'Elixir, Erlang and Rust toolchains: '};
    case 'repository-document-review@1':return {label:PROFILE_LABELS[result.profile],detail:many(n,'reviewed document'),toolchain:null};
    case 'repository-python-gate@1':return {label:PROFILE_LABELS[result.profile],detail:many(n,'repository gate'),toolchain:null};
    default:return {label:profileLabelFor(result?.profile),detail:n+' test '+(n===1?'file':'files'),toolchain:null};
  }
}

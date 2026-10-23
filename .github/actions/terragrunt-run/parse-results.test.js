const test = require('node:test');
const assert = require('node:assert/strict');

const parseResults = require('./parse-results.js');

function makeCore() {
  const outputs = {};
  return {
    outputs,
    setOutput(name, value) {
      outputs[name] = String(value);
    },
    info() {},
    setFailed(message) {
      this.failed = message;
    },
  };
}

function makeGithub({ jobs = [], throwError = false } = {}) {
  return {
    paginate: async () => {
      if (throwError) throw new Error('API error');
      return jobs;
    },
    rest: {
      actions: {
        listJobsForWorkflowRun: () => {},
      },
    },
  };
}

function makeContext() {
  return {
    repo: { owner: 'panicboat', repo: 'panicboat-actions' },
    runId: 12345,
  };
}

function makeArgs(overrides = {}) {
  return {
    inputs: {
      'action-type': 'plan',
      'service-name': 'test-service',
      'environment': 'develop',
      ...(overrides.inputs ?? {}),
    },
    steps: {
      terragrunt: {
        outputs: {
          tg_action_exit_code: '0',
          tg_action_output: 'Sample terragrunt output',
          ...(overrides.stepOutputs ?? {}),
        },
      },
    },
    github: overrides.github ?? makeGithub(),
    context: overrides.context ?? makeContext(),
  };
}

test.beforeEach(() => {
  process.env.GITHUB_SERVER_URL = 'https://github.com';
  process.env.GITHUB_REPOSITORY = 'panicboat/panicboat-actions';
  process.env.GITHUB_RUN_ID = '12345';
  process.env.RUNNER_NAME = 'GitHub Actions 2';
  process.env.GITHUB_JOB = 'terragrunt-plan';
});

test('truncation-notice is empty string when output fits within limit', async () => {
  const core = makeCore();
  await parseResults({ core, ...makeArgs() });
  assert.equal(core.outputs['truncation-notice'], '');
});

test('truncation-notice uses job URL when output exceeds limit and matching job found', async () => {
  const core = makeCore();
  const longOutput = 'x'.repeat(30001);
  const jobUrl = 'https://github.com/panicboat/panicboat-actions/actions/runs/12345/job/99999';
  const github = makeGithub({
    jobs: [
      {
        name: 'terragrunt-plan',
        runner_name: 'GitHub Actions 2',
        status: 'in_progress',
        html_url: jobUrl,
      },
    ],
  });
  await parseResults({
    core,
    ...makeArgs({ stepOutputs: { tg_action_output: longOutput }, github }),
  });
  assert.equal(
    core.outputs['truncation-notice'],
    `> ⚠️ Output truncated. [View full logs](${jobUrl}) for complete details.`,
  );
});

test('output is truncated to maxLength and contains no trailing notice when over limit', async () => {
  const core = makeCore();
  const longOutput = 'x'.repeat(30001);
  await parseResults({
    core,
    ...makeArgs({ stepOutputs: { tg_action_output: longOutput } }),
  });
  assert.equal(core.outputs['output'].length, 30000);
  assert.ok(!core.outputs['output'].includes('output truncated'));
  assert.ok(!core.outputs['output'].includes('see workflow logs'));
});

test('job-url output is set to matched job html_url by runner_name', async () => {
  const core = makeCore();
  const jobUrl = 'https://github.com/panicboat/panicboat-actions/actions/runs/12345/job/99999';
  const github = makeGithub({
    jobs: [
      {
        name: 'other-job',
        runner_name: 'GitHub Actions 1',
        status: 'completed',
        html_url: 'https://example.invalid/other',
      },
      {
        name: 'terragrunt-plan',
        runner_name: 'GitHub Actions 2',
        status: 'in_progress',
        html_url: jobUrl,
      },
    ],
  });
  await parseResults({ core, ...makeArgs({ github }) });
  assert.equal(core.outputs['job-url'], jobUrl);
});

test('job-url falls back to run URL when no in_progress job matches', async () => {
  const core = makeCore();
  const github = makeGithub({
    jobs: [
      {
        name: 'terragrunt-plan',
        runner_name: 'GitHub Actions 1',
        status: 'completed',
        html_url: 'https://example.invalid/completed',
      },
    ],
  });
  await parseResults({ core, ...makeArgs({ github }) });
  assert.equal(
    core.outputs['job-url'],
    'https://github.com/panicboat/panicboat-actions/actions/runs/12345',
  );
});

test('job-url falls back to run URL when API call fails', async () => {
  const core = makeCore();
  const github = makeGithub({ throwError: true });
  await parseResults({ core, ...makeArgs({ github }) });
  assert.equal(
    core.outputs['job-url'],
    'https://github.com/panicboat/panicboat-actions/actions/runs/12345',
  );
});

test('job-url matches by GITHUB_JOB name when runner_name does not match', async () => {
  const core = makeCore();
  const jobUrl = 'https://github.com/panicboat/panicboat-actions/actions/runs/12345/job/77777';
  const github = makeGithub({
    jobs: [
      {
        name: 'terragrunt-plan',
        runner_name: 'unknown-runner',
        status: 'in_progress',
        html_url: jobUrl,
      },
    ],
  });
  await parseResults({ core, ...makeArgs({ github }) });
  assert.equal(core.outputs['job-url'], jobUrl);
});

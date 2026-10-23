const { execSync } = require('child_process');

module.exports = async ({ core, inputs }) => {
  try {
    core.info('🔐 Verifying AWS credentials');

    const actionType = inputs['action-type'];
    const planRole = inputs['plan-iam-role'];
    const applyRole = inputs['apply-iam-role'];
    const region = inputs['aws-region'];
    const environment = inputs['environment'];

    const role = actionType === 'plan' ? planRole : applyRole;
    const sessionName = `GitHubActions-Terragrunt-${actionType}-${environment}`;

    core.info(`Role: ${role}`);
    core.info(`Region: ${region}`);
    core.info(`Session: ${sessionName}`);

    // Execute AWS STS get-caller-identity
    const output = execSync('aws sts get-caller-identity', { encoding: 'utf8' });
    core.info(output);

    core.info('✅ AWS credentials configured successfully');

  } catch (error) {
    core.setFailed(`AWS credential verification failed: ${error.message}`);
    throw error;
  }
};

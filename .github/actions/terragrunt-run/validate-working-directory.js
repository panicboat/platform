const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

module.exports = async ({ core, inputs }) => {
  try {
    core.info('🔍 Validating working directory');

    const workingDirectory = inputs['working-directory'];
    const serviceName = inputs['service-name'];
    const environment = inputs['environment'];
    const actionType = inputs['action-type'];

    core.info(`Working Directory: ${workingDirectory}`);
    core.info(`Service: ${serviceName}`);
    core.info(`Environment: ${environment}`);
    core.info(`Action Type: ${actionType}`);

    // Check if working directory exists
    if (!fs.existsSync(workingDirectory)) {
      core.error(`Working directory '${workingDirectory}' does not exist`);
      core.error('This may indicate a configuration issue or the service structure has changed.');

      // Show available directories to help with debugging
      core.info('Available directories:');
      try {
        const output = execSync('find . -type d -name "*terragrunt*" -o -name "*' + serviceName + '*" | head -10',
          { encoding: 'utf8' });
        core.info(output);
      } catch (error) {
        core.warning(`Could not list directories: ${error.message}`);
      }

      core.setFailed(`Working directory '${workingDirectory}' does not exist`);
      return;
    }

    // Check for terragrunt.hcl file
    const terragruntHcl = path.join(workingDirectory, 'terragrunt.hcl');
    if (!fs.existsSync(terragruntHcl)) {
      core.warning(`No terragrunt.hcl found in ${workingDirectory}`);
      core.warning('This may be expected depending on the service structure.');
    }

    core.info(`✅ Working directory validated: ${workingDirectory}`);

  } catch (error) {
    core.setFailed(`Working directory validation failed: ${error.message}`);
    throw error;
  }
};

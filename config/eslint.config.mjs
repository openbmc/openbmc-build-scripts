import eslintPluginJsonc from 'eslint-plugin-jsonc';
import fs from 'fs';

// Retrieve the default configuration
const defaultConfig = eslintPluginJsonc.configs['flat/recommended-with-jsonc'];

// Ensure defaultConfig.ignores is an array
defaultConfig.ignores = defaultConfig.ignores || [];

// Append additional ignore patterns to the default configuration
const customConfig = [
    ...defaultConfig,
    {
    ignores: [
        ...defaultConfig.ignores,
        "**/meson-*/*.json",
        "subprojects/**/*.json"
    ]}
];

try {
    // Attempt to read the .eslintIgnore file
    const eslintIgnoreContent = fs.readFileSync('.eslintIgnore', 'utf8');
    // Split the content by new lines and remove empty lines
    const ignorePatterns = eslintIgnoreContent.split('\n').filter(pattern => pattern.trim() !== '');
    if (ignorePatterns.length > 0) {
        // Ensure customConfig.ignores is an array
        const ignoresIndex = customConfig.findIndex(obj => 'ignores' in obj);
        if (ignoresIndex !== -1) {
            customConfig[ignoresIndex].ignores = customConfig[ignoresIndex].ignores || [];
            // Append the local ignores to the existing configuration
            customConfig[ignoresIndex].ignores.push(...ignorePatterns);
        }
    }
} catch (error) {
    // Handle the case where the .eslintIgnore file is not present
    console.info('\x1b[32m','Repo specific ignores are not present');
}

export default customConfig;

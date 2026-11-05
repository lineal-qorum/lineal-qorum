import { DEVELOPMENT } from '@env';

export const isDev: boolean = DEVELOPMENT.debug;

export const MICROSERVICES_BASE_URL = 'https://microservices.qorum.one';

console.log('[Config] Microservices URL configured as:', MICROSERVICES_BASE_URL, `(Dev: ${isDev})`);

import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';

const page = new URL('./index.html', import.meta.url);
const server = createServer(async (_request, response) => {
  try {
    response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    response.end(await readFile(page));
  } catch {
    response.writeHead(500);
    response.end('No se pudo abrir index.html');
  }
});

server.listen(18766, '127.0.0.1', () => {
  console.log('Web: http://127.0.0.1:18766');
});

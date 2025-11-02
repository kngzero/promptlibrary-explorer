const CACHE_NAME = 'promptlibrary-explorer-v1';
const urlsToCache = [
  '/',
  '/index.html',
  'https://storage.googleapis.com/prompt-library-presets-nb25/lightportrait.png',
  'https://storage.googleapis.com/prompt-library-presets-nb25/artgallery-reference.jpg',
  'https://storage.googleapis.com/aistudio-hosting/presets/02.png',
  'https://storage.googleapis.com/aistudio-hosting/presets/03.png',
  'https://storage.googleapis.com/aistudio-hosting/presets/04.png',
  'https://storage.googleapis.com/aistudio-hosting/presets/05.png',
  'https://storage.googleapis.com/aistudio-hosting/presets/06.png',
  'https://storage.googleapis.com/aistudio-hosting/presets/07.png',
  'https://storage.googleapis.com/aistudio-hosting/presets/08.png',
  'https://storage.googleapis.com/aistudio-hosting/presets/09.png',
  'https://storage.googleapis.com/aistudio-hosting/presets/10.png',
  'https://storage.googleapis.com/aistudio-hosting/presets/11.png',
  'https://storage.googleapis.com/aistudio-hosting/presets/12.png',
  'https://storage.googleapis.com/aistudio-hosting/presets/12_ref.png',
  'https://storage.googleapis.com/aistudio-hosting/presets/13.png',
  'https://storage.googleapis.com/aistudio-hosting/presets/14.png',
  'https://storage.googleapis.com/aistudio-hosting/presets/15.png',
  'https://storage.googleapis.com/aistudio-hosting/presets/16.png',
];

self.addEventListener('install', event => {
  self.skipWaiting();
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then(cache => {
        return cache.addAll(urlsToCache);
      })
  );
});

self.addEventListener('activate', event => {
  const cacheWhitelist = [CACHE_NAME];
  event.waitUntil(
    caches.keys().then(cacheNames => {
      return Promise.all(
        cacheNames.map(cacheName => {
          if (cacheWhitelist.indexOf(cacheName) === -1) {
            return caches.delete(cacheName);
          }
        })
      );
    })
  );
});

self.addEventListener('fetch', event => {
  event.respondWith(
    caches.match(event.request)
      .then(response => {
        // Cache hit - return response
        if (response) {
          return response;
        }

        const fetchRequest = event.request.clone();

        return fetch(fetchRequest).then(
          response => {
            // Check if we received a valid response
            if (!response || response.status !== 200) {
              return response;
            }
            
            // We don't cache non-GET requests or responses from CDNs to avoid issues.
            if(event.request.method !== 'GET' || response.type === 'opaque') {
                return response;
            }

            const responseToCache = response.clone();

            caches.open(CACHE_NAME)
              .then(cache => {
                cache.put(event.request, responseToCache);
              });

            return response;
          }
        );
      })
  );
});

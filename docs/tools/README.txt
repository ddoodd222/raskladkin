zoom.js — крупный план элементов страницы в 2x для самопроверки после правок.
Запуск: поднять сервер `python3 -m http.server 8765 --directory docs`, затем из папки с установленным playwright:
  node zoom.js ".selector1" ".selector2"
Playwright ставится так: npm i playwright@1.49.1 && npx playwright install chromium

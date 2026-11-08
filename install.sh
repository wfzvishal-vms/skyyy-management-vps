#!/bin/bash
set -e
echo "🌌 Installing Sky Management Panel..."
echo "Copyright (c) 2026 Vishal" > LICENSE
pip install -q flask psutil
if [ ! -f app.py ]; then
  echo "❌ app.py not found. Please download it first."
  echo "Run: curl -sL https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/app.py -o app.py"
  exit 1
fi
echo "🚀 Starting Sky Panel at http://0.0.0.0:5000"
echo "👤 Login: admin / admin123"
python app.py

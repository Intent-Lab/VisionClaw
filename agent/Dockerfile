FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .
# Model files (VAD etc.) download at first start unless prefetched here.
RUN python main.py download-files || true
CMD ["python", "main.py", "start"]

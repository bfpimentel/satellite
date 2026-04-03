# Build stage
FROM python:3.11-slim AS builder

WORKDIR /app

# Install uv
RUN pip install uv

# Copy dependency files
COPY pyproject.toml uv.lock ./

# Install dependencies using uv
RUN uv pip install --system -e .

# Production stage
FROM python:3.11-slim

WORKDIR /app

# Copy installed packages from builder
COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin

# Copy application files
COPY server.py ./
COPY templates/ ./templates/
COPY static/ ./static/

# Create data directory for persistence
RUN mkdir -p /app/data

# Expose port
EXPOSE 6333

# Run the application
CMD ["python", "-m", "flask", "run"]

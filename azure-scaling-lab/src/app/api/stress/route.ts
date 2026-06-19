import { NextResponse } from 'next/server';

export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const duration = parseInt(searchParams.get('duration') || '3', 10);

  // CAP: Prevent infinite loops or huge delays
  const safeDuration = Math.min(Math.max(duration, 1), 30); 

  // THE SOLUTION: Non-blocking delay
  // This does NOT block the Node.js event loop.
  // The server can still accept 1000 other requests while this one "waits".
  await new Promise((resolve) => setTimeout(resolve, safeDuration * 1000));

  return NextResponse.json({
    status: "success",
    message: `Request held for ${safeDuration} seconds`,
    // Optional: Log the PID to prove different replicas are handling requests
    pid: process.pid 
  });
}
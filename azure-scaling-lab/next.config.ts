import type { NextConfig } from "next";


const nextConfig: NextConfig = {
  // This enables the 'standalone' output
  output: 'standalone',
  
  // Optional: Ensure images work if you host on ACA with external domains
  images: {
    remotePatterns: [
      {
        protocol: 'https',
        hostname: '**',
      },
    ],
  },
};

export default nextConfig;

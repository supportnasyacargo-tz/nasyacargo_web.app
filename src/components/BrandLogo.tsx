import nasyaLogo from '../imports/nasya-logo.png'

interface BrandLogoProps {
  className?: string
  priority?: boolean
}

export default function BrandLogo({ className = '', priority = false }: BrandLogoProps) {
  return (
    <img
      src={nasyaLogo}
      alt="Nasya Cargo"
      className={`brand-logo ${className}`}
      decoding="async"
      loading={priority ? 'eager' : 'lazy'}
    />
  )
}

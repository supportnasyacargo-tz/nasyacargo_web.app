import nasyaLogo from '../imports/nasya-logo.png'

export function companyLogoUrl(logoPath?: string): string {
  return logoPath?.trim() || nasyaLogo
}

import Link from "next/link";

export function Brand() {
  return (
    <Link href="/" className="brand" aria-label="FishingMeta home">
      <img src="/fishingmeta.svg" alt="" />
      <span className="name">FishingMeta</span>
    </Link>
  );
}

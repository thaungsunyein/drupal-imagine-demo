<?php

declare(strict_types=1);

namespace Drupal\imagine_migrate\Plugin\migrate\source;

use Drupal\Core\Site\Settings;
use Drupal\imagine_migrate\ImagineSource;
use Drupal\migrate\MigrateException;
use Drupal\migrate\Plugin\migrate\source\SourcePluginBase;

/**
 * Shared plumbing for the Imagine source plugins.
 *
 * Configuration common to all of them:
 * - source_dir: (optional) content folder; defaults to the
 *   'imagine_source_dir' setting from settings.php.
 * - book_ids: (optional) only read these books; defaults to the
 *   'imagine_book_ids' setting from settings.php, else every book.
 */
abstract class ImagineSourceBase extends SourcePluginBase {

  /**
   * The content reader, created on first use.
   */
  private ?ImagineSource $imagine = NULL;

  /**
   * Returns the reader for the configured content folder.
   *
   * @throws \Drupal\migrate\MigrateException
   *   When the folder is not set or does not exist.
   */
  protected function imagine(): ImagineSource {
    if ($this->imagine === NULL) {
      $dir = $this->configuration['source_dir'] ?? Settings::get('imagine_source_dir');
      if (!$dir || !is_dir($dir)) {
        throw new MigrateException(sprintf('Imagine content folder not found: "%s". Set imagine_source_dir in settings.php.', $dir));
      }
      $this->imagine = new ImagineSource($dir);
    }
    return $this->imagine;
  }

  /**
   * Returns the books to read, after the book_ids filter.
   *
   * @param bool|null $translations
   *   TRUE for translations only, FALSE for originals only, NULL for both.
   *
   * @return array<string, array>
   *   Bibles keyed by book id.
   */
  protected function selectedBooks(?bool $translations = NULL): array {
    $books = $this->imagine()->books();
    $bookIds = $this->configuration['book_ids'] ?? Settings::get('imagine_book_ids');
    if (isset($bookIds)) {
      $books = array_intersect_key($books, array_flip($bookIds));
    }
    if ($translations !== NULL) {
      $books = array_filter($books, fn(array $bible) => isset($bible['translationOf']) === $translations);
    }
    return $books;
  }

  /**
   * {@inheritdoc}
   */
  public function __toString(): string {
    return $this->pluginId;
  }

}

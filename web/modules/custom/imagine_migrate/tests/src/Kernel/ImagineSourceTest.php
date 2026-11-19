<?php

declare(strict_types=1);

namespace Drupal\Tests\imagine_migrate\Kernel;

use Drupal\KernelTests\KernelTestBase;
use Drupal\migrate\Plugin\MigrateSourceInterface;

/**
 * Tests the Imagine source plugins against the fixture content folder.
 *
 * The fixtures are a trimmed copy of the real Imagine layout: the English
 * Alice with two sections (text only for chapter 1), its French translation,
 * one narration file per book, two English scene images and a cover each.
 *
 * @group imagine_migrate
 */
final class ImagineSourceTest extends KernelTestBase {

  /**
   * {@inheritdoc}
   */
  protected static $modules = ['migrate', 'migrate_plus', 'imagine_migrate'];

  /**
   * {@inheritdoc}
   */
  protected function setUp(): void {
    parent::setUp();
    $this->setSetting('imagine_source_dir', dirname(__DIR__, 2) . '/fixtures/content');
  }

  /**
   * Builds a throwaway migration and returns its source plugin.
   */
  private function source(array $config): MigrateSourceInterface {
    $migration = $this->container->get('plugin.manager.migration')->createStubMigration([
      'id' => 'test_' . $config['plugin'],
      'source' => $config,
      'process' => [],
      'destination' => ['plugin' => 'null'],
    ]);
    return $migration->getSourcePlugin();
  }

  /**
   * Returns every row's source values.
   */
  private function rows(array $config): array {
    $rows = [];
    foreach ($this->source($config) as $row) {
      $rows[] = $row->getSource();
    }
    return $rows;
  }

  /**
   * Originals and translations come out of separate passes.
   */
  public function testBooksSplitByTranslation(): void {
    $originals = $this->rows(['plugin' => 'imagine_bible', 'translations' => FALSE]);
    $this->assertSame(['alice-in-wonderland'], array_column($originals, 'id'));
    $this->assertNull($originals[0]['translation_of']);
    $this->assertSame('Lewis Carroll', $originals[0]['author']);
    $this->assertSame(1865, $originals[0]['first_published']);
    $this->assertSame('alice-in-wonderland/cover.webp', $originals[0]['cover_asset_id']);

    $translations = $this->rows(['plugin' => 'imagine_bible', 'translations' => TRUE]);
    $this->assertSame(['alice-au-pays-des-merveilles'], array_column($translations, 'id'));
    $this->assertSame('alice-in-wonderland', $translations[0]['translation_of']);
    $this->assertSame('fr', $translations[0]['language']);
    $this->assertSame('Henri Bué', $translations[0]['translator']);
  }

  /**
   * A book_ids list limits which books are read.
   */
  public function testBookIdsFilter(): void {
    $rows = $this->rows([
      'plugin' => 'imagine_bible',
      'translations' => TRUE,
      'book_ids' => ['some-other-book'],
    ]);
    $this->assertSame([], $rows);
  }

  /**
   * Chapter 2 has no narration file, so only chapter 1 of each book appears.
   */
  public function testAssetsSkipMissingFiles(): void {
    $rows = $this->rows(['plugin' => 'imagine_asset', 'kind' => 'narration']);
    $ids = array_column($rows, 'asset_id');
    sort($ids);
    $this->assertSame([
      'alice-au-pays-des-merveilles/narration/1.mp3',
      'alice-in-wonderland/narration/1.mp3',
    ], $ids);
    foreach ($rows as $row) {
      $this->assertFileExists($row['path']);
      $this->assertSame(1, $row['chapter_index']);
    }
  }

  /**
   * The French book borrows the English artwork, so it has no scene rows.
   */
  public function testTranslationsHaveNoOwnScenes(): void {
    $rows = $this->rows(['plugin' => 'imagine_asset', 'kind' => 'scene']);
    $this->assertSame([
      'alice-in-wonderland/scenes/1-0.webp',
      'alice-in-wonderland/scenes/1-1.webp',
    ], array_column($rows, 'asset_id'));
    $this->assertNotContains('alice-au-pays-des-merveilles', array_column($rows, 'book_id'));
  }

  /**
   * Each book with a cover file gets one cover row.
   */
  public function testCovers(): void {
    $rows = $this->rows(['plugin' => 'imagine_asset', 'kind' => 'cover']);
    $this->assertCount(2, $rows);
    $this->assertNull($rows[0]['chapter_index']);
  }

}
